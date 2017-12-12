#include "opencv2\opencv.hpp"
#include "img_cuda.h"
#include "cuda_runtime.h"
#include "img_helper.h"
#include "device_launch_parameters.h"

#include <chrono>
#include <stdio.h>

using namespace cv;
using namespace std;

#define THREADS 256

__global__ void kernel_grayscale(pixel * src, int16_t * dst, const int elements) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;

	if(index < elements)
		dst[index] = (int16_t)(src[index].b + src[index].r + src[index].g) / 3;
}

// Extend this image with a 1 pixel border with value 0;
__global__ void kernel_gaussian(int16_t * src, int16_t * dst, matrix mat, const int width, const int height) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	int pixelValue;
	int pixelAcc = 0;
	const int noElements = width * height;

	if (index < noElements) {
		/* The if statement make sure that only pixels with eight neigbours are being affected */
		/*  NOT TOP ROW       && NOT BOTTOM ROW               && NOT FIRST COLUMN && NOT LAST COLUMN        */
		if (index > width - 1 && index < width*(height - 1)-1 && index%width != 0 && index%width != width-1) {
			for (int i = 0; i < 3; i++)
			{
				for (int j = 0; j < 3; j++)
				{
					int rowOffset = (i - 1)*width;
					int elementOffset = (j - 1);
					int pixel_index = index + rowOffset + elementOffset;

					pixelAcc += mat.element[i][j] * src[pixel_index];

				}
			}
		}
		else {
			//element is on the edge
			pixelAcc = src[index] * 16;
		}
		dst[index] = pixelAcc/16;
		pixelAcc = 0;
	}

}

__global__ void kernel_sobel(int16_t * src, int16_t * dst, matrix mat, const int width, const int height) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	int pixelValue;
	int pixelAcc = 0;
	const int noElements = width * height;

	if (index < noElements) {
		/* The if statement make sure that only pixels with eight neigbours are being affected */
		/*  NOT TOP ROW       && NOT BOTTOM ROW               && NOT FIRST COLUMN && NOT LAST COLUMN        */
		if (index > width - 1 && index < width*(height - 1) - 1 && index%width != 0 && index%width != width - 1) {
			for (int i = 0; i < 3; i++)
			{
				for (int j = 0; j < 3; j++)
				{
					int rowOffset = (i - 1)*width;
					int elementOffset = (j - 1);
					int pixel_index = index + rowOffset + elementOffset;

					pixelAcc += mat.element[i][j] * src[pixel_index];
					
				}
			}
		}
		else {
			//element is on the edge
			pixelAcc = src[index];
		}
		dst[index] = pixelAcc;

		pixelAcc = 0;
	}
}

__global__ void kernel_combo_sobel(int16_t * src, int16_t * gx, int16_t * gy, matrix matx, matrix maty, const int width, const int height) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	int pixelValue;
	int pixelAccX = 0;
	int pixelAccY = 0;
	const int noElements = width * height;
	int16_t pixel;

	if (index < noElements) {
		/* The if statement make sure that only pixels with eight neigbours are being affected */
		/*  NOT TOP ROW       && NOT BOTTOM ROW               && NOT FIRST COLUMN && NOT LAST COLUMN        */
		if (index > width - 1 && index < width*(height - 1) - 1 && index%width != 0 && index%width != width - 1) {
			for (int i = 0; i < 3; i++)
			{
				for (int j = 0; j < 3; j++)
				{
					int rowOffset = (i - 1)*width;
					int elementOffset = (j - 1);
					int pixel_index = index + rowOffset + elementOffset;
					pixel = src[pixel_index];
					pixelAccX += matx.element[i][j] * pixel;
					pixelAccY += maty.element[i][j] * pixel;

				}
			}
		}
		else {
			//element is on the edge
			pixel = src[index];
			pixelAccX = pixel;
			pixelAccY = pixel;
		}
		gx[index] = pixelAccX;
		gy[index] = pixelAccY;

	}
}

/* Pixel pyth */
__global__ void kernel_pythagorean(int16_t *dst, int16_t *gx, int16_t *gy, const int elements) {
	
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	const float compressionFactor = 255.0f / 1445.0f;

	int pixelGx, pixelGy;
	if (index < elements)
	{
		pixelGx = gx[index] * gx[index];
		pixelGy = gy[index] * gy[index];

		dst[index] = (int16_t)(sqrtf((float)pixelGx + (float)pixelGy) * compressionFactor); //Cast to float since CUDA sqrtf overload is float/double
	}
}

__global__ void kernel_findMaxPixel(int16_t *src, const int elements, int *maxPixel) {
	extern __shared__ int shared[];

	int tid = threadIdx.x;
	int gid = (blockDim.x * blockIdx.x) + tid;
	shared[tid] = -INT_MAX;  // 1

	if (gid < elements)
		shared[tid] = src[gid];
	__syncthreads();

	for (unsigned int s = blockDim.x / 2; s>0; s >>= 1)
	{
		if (tid < s && gid < elements)
			shared[tid] = max(shared[tid], shared[tid + s]);  // 2
		__syncthreads();
	}


	// what to do now?
	// option 1: save block result and launch another kernel
	//if (tid == 0)
	//d_max[blockIdx.x] = shared[tid]; // 3
	// option 2: use atomics
	if (tid == 0)
	{
		atomicMax(maxPixel, shared[0]);
	}

}

__global__ void kernel_normalize(int16_t *src, const int elements, int *maxPixel)
{
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	int stride = blockDim.x * gridDim.x;
	const float factor = 255.0f / (float)*maxPixel;

	if(index == 0)
		printf("CUDA max pixel: %d\n", *maxPixel);

	while (index < elements)
	{
		src[index] = src[index] * factor;
		index += stride;
	}
}

void cuda_edge_detection(int16_t * src, Mat * image) {
	pixel * h_src_image;
	int16_t * h_dst_image;
	matrix matrix;
	pixel * d_src_image;
	int16_t * d_dst_image;
	int16_t * d_result_image;
	int16_t * d_sobelGx_image;
	int16_t * d_sobelGy_image;
	int * d_maxPixel;

	const int width = image->cols;
	const int height = image->rows;
	const int elements = width * height;

	chrono::high_resolution_clock::time_point start, stop;
	chrono::duration<float> execTime;

	h_src_image = (pixel *)malloc(elements * sizeof(pixel));
	h_dst_image = (int16_t *)malloc(elements * sizeof(int16_t));

	const int blocks = (elements / THREADS) + 1;

	matToArray(image,h_src_image);
	
	start = chrono::high_resolution_clock::now();
	cudaMalloc((void**)&d_src_image, elements * sizeof(pixel));
	cudaMalloc((void**)&d_dst_image, elements * sizeof(int16_t));
	cudaMalloc((void**)&d_result_image, elements * sizeof(int16_t));
	cudaMalloc((void**)&d_sobelGx_image, elements * sizeof(int16_t));
	//cudaMalloc((void**)&d_sobelGy_image, elements * sizeof(int16_t));
	cudaMalloc((void**)&d_maxPixel, sizeof(int));
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Malloc time:          %f\n", execTime.count());

	/* Transfer image data*/
	start = chrono::high_resolution_clock::now();
	cudaMemcpy(d_src_image, h_src_image, elements * sizeof(pixel), cudaMemcpyHostToDevice);
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Transfer time:        %f\n", execTime.count());

	/* Make grayscale*/
	start = chrono::high_resolution_clock::now();
	kernel_grayscale <<<blocks, THREADS>>>(d_src_image, d_dst_image, elements);
	cudaDeviceSynchronize();
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Grayscale time:       %f\n", execTime.count());

	/* Gaussian Blur */
	start = chrono::high_resolution_clock::now();
	getGaussianKernel(&matrix);
	kernel_gaussian <<<blocks, THREADS>>>(d_dst_image, d_result_image, matrix, width, height);
	cudaDeviceSynchronize();
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Gaussian time:        %f\n", execTime.count());

	/* Multiplication with Gx */
	start = chrono::high_resolution_clock::now();
	getGxKernel(&matrix);
	kernel_sobel <<<blocks, THREADS>>>(d_result_image, d_sobelGx_image, matrix, width, height);
	cudaDeviceSynchronize();
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Gx time:              %f\n", execTime.count());

	/* Multiplication with Gy */
	start = chrono::high_resolution_clock::now();
	getGyKernel(&matrix);
	kernel_sobel <<<blocks, THREADS>>>(d_result_image, d_dst_image, matrix, width, height);
	cudaDeviceSynchronize();
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Gy time:              %f\n", execTime.count());

	/* Pythagorean with Gx and Gy */
	start = chrono::high_resolution_clock::now();
	kernel_pythagorean <<<blocks, THREADS>>>(d_result_image, d_sobelGx_image, d_dst_image, elements);
	cudaDeviceSynchronize();
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Pyth time:            %f\n", execTime.count());

	/* Map values to max 255, allocate 4*THREADS bytes shared memory */
	start = chrono::high_resolution_clock::now();
	kernel_findMaxPixel<<<blocks,THREADS,4*THREADS>>>(d_result_image, elements, d_maxPixel);
	cudaDeviceSynchronize();
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Max pixel time:       %f\n", execTime.count());

	/* Map values to max 255, allocate 4*THREADS bytes shared memory */
	start = chrono::high_resolution_clock::now();
	kernel_normalize <<<blocks, THREADS>>>(d_result_image, elements, d_maxPixel);
	cudaDeviceSynchronize();
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Normalize time:       %f\n", execTime.count());

	start = chrono::high_resolution_clock::now();
	cudaMemcpy(src, d_result_image, elements * sizeof(int16_t), cudaMemcpyDeviceToHost);
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Transfer time:        %f\n", execTime.count());

	cudaError_t error = cudaGetLastError();
	if (error != cudaSuccess)
	{
		fprintf(stderr, "ERROR: %s\n", cudaGetErrorString(error));
	}

	cudaFree(d_src_image);
	cudaFree(d_dst_image);
	free(h_src_image);
	free(h_dst_image);

}

void init_cuda() {
	cudaFree(0); // Init cuda
}