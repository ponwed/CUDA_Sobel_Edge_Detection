#include <chrono>
#include <stdio.h>

#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#ifndef CUDA
#include "img_cuda.h"
#endif

#ifndef HELPER
#include "img_helper.h"
#endif


using namespace cv;
using namespace std;

#define THREADS 256

/* Set CUDATIME to 1 to print duration for each kernel */
#define CUDATIME 0

/* Convert RGB pixel values of src to greyscale values and store in dst */
__global__ void kernel_grayscale(pixel * src, int16_t * dst, const int elements) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;

	if(index < elements)
		dst[index] = (int16_t)(src[index].b + src[index].r + src[index].g) / 3;
}

/* Apply gaussian filter (mat) to pixel values in src and store in dst */
__global__ void kernel_gaussian(int16_t * src, int16_t * dst, matrix mat, const int width, const int height) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	float pixelAcc = 0;
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
			dst[index] = pixelAcc / 16;
		}
		else {
			//element is on the edge
			dst[index] = src[index];
		}
	}

}

/* Calculate approximation of horizontal or vertical deratives in src using sobel matrix stored in mat and
save result in dst */
__global__ void kernel_sobel(int16_t * src, int16_t * dst, matrix mat, const int width, const int height) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;
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

		dst[index] = pixelAcc;

	}
}


/* Combine gradient approximations of gx and gy using pythagoreans theorem to get gradient magitude
and store the result in dst */
__global__ void kernel_pythagorean(int16_t *dst, int16_t *gx, int16_t *gy, const int elements, int *maxPixel) {
	
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	const float compressionFactor = 255.0f / 1445.0f;

	int pixelGx, pixelGy;
	if (index < elements)
	{
		pixelGx = gx[index] * gx[index];
		pixelGy = gy[index] * gy[index];
		int16_t value = (int16_t)(sqrtf((float)pixelGx + (float)pixelGy) * compressionFactor);
			dst[index] = value;//(int16_t)(sqrtf((float)pixelGx + (float)pixelGy) * compressionFactor); //Cast to float since CUDA sqrtf overload is float/double

		atomicMax(maxPixel, value);
	}
}

/* Normalize pixel values in src to give a resulting image with clearer edges */
__global__ void kernel_normalize(int16_t *src, const int elements, int *maxPixel)
{
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	int stride = blockDim.x * gridDim.x;
	const float factor = 255.0f / (float)*maxPixel;

	while (index < elements)
	{
		src[index] = src[index] * factor;
		index += stride;
	}
}

void cuda_edge_detection(int16_t * src, pixel * pixel_array, const int width, const int height) {
	int16_t * h_dst_image;
	matrix matrix;
	pixel * d_pixel_array;
	int16_t * d_int16_array_1;
	int16_t * d_int16_array_2;
	int16_t * d_int16_array_3;
	int * d_maxPixel;

	const int elements = width * height;
	const int blocks = (elements / THREADS) + 1;


#if CUDATIME > 0
	chrono::high_resolution_clock::time_point start, stop;
	chrono::duration<float> execTime;
	start = chrono::high_resolution_clock::now();
#endif
	h_dst_image = (int16_t *)malloc(elements * sizeof(int16_t));
	cudaMalloc((void**)&d_pixel_array, elements * sizeof(pixel));
	cudaMalloc((void**)&d_int16_array_1, elements * sizeof(int16_t));
	cudaMalloc((void**)&d_int16_array_2, elements * sizeof(int16_t));
	cudaMalloc((void**)&d_int16_array_3, elements * sizeof(int16_t));
	cudaMalloc((void**)&d_maxPixel, sizeof(int));
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Malloc time:          %f\n", execTime.count());
#endif

	/* Transfer image data*/
#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	cudaMemcpy(d_pixel_array, pixel_array, elements * sizeof(pixel), cudaMemcpyHostToDevice);
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Transfer time:        %f\n", execTime.count());
#endif

	/* Make grayscale*/
#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	kernel_grayscale <<<blocks, THREADS>>>(d_pixel_array, d_int16_array_1, elements);
	cudaDeviceSynchronize();
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Grayscale time:       %f\n", execTime.count());
#endif

	/* Gaussian Blur */
#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	getGaussianKernel(&matrix);
	kernel_gaussian <<<blocks, THREADS>>>(d_int16_array_1, d_int16_array_2, matrix, width, height);
	cudaDeviceSynchronize();
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Gaussian time:        %f\n", execTime.count());
#endif

	/* Multiplication with Gx */
#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	getGxKernel(&matrix);
	kernel_sobel <<<blocks, THREADS>>>(d_int16_array_2, d_int16_array_3, matrix, width, height);
	cudaDeviceSynchronize();
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Gx time:              %f\n", execTime.count());
#endif

	/* Multiplication with Gy */
#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	getGyKernel(&matrix);
	kernel_sobel <<<blocks, THREADS>>>(d_int16_array_2, d_int16_array_1, matrix, width, height);
	cudaDeviceSynchronize();
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Gy time:              %f\n", execTime.count());
#endif

	/* Pythagorean with Gx and Gy */
#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	kernel_pythagorean <<<blocks, THREADS>>>(d_int16_array_2, d_int16_array_3, d_int16_array_1, elements, d_maxPixel);
	cudaDeviceSynchronize();
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Pyth time:            %f\n", execTime.count());
#endif

	/* Map values to max 255, allocate 4*THREADS bytes shared memory */
#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	kernel_normalize <<<blocks, THREADS>>>(d_int16_array_2, elements, d_maxPixel);
	cudaDeviceSynchronize();
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Normalize time:       %f\n", execTime.count());
#endif

#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	cudaMemcpy(src, d_int16_array_2, elements * sizeof(int16_t), cudaMemcpyDeviceToHost);
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Transfer time:        %f\n", execTime.count());
#endif

	cudaError_t error = cudaGetLastError();
	if (error != cudaSuccess)
	{
		fprintf(stderr, "ERROR: %s\n", cudaGetErrorString(error));
	}


#if CUDATIME > 0
	start = chrono::high_resolution_clock::now();
#endif
	cudaFree(d_pixel_array);
	cudaFree(d_int16_array_1);
	cudaFree(d_int16_array_2);
	cudaFree(d_int16_array_3);
	cudaFree(d_maxPixel);
	free(h_dst_image);
#if CUDATIME > 0
	stop = chrono::high_resolution_clock::now();
	execTime = chrono::duration_cast<chrono::duration<float>>(stop - start);
	printf("Free time:            %f\n", execTime.count());
#endif

}

void init_cuda() {
	cudaFree(0); // Init cuda
}