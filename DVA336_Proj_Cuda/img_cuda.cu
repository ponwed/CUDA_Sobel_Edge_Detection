#include "opencv2\opencv.hpp"
#include "img_cuda.h"
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <stdio.h>

using namespace cv;

__global__ void kernel_grayscale(pixel * img) {


}

__global__ void kernel_gaussian() {

}

__global__ void kernel_sobel() {

}

__global__ void kernel_normalize() {

}

void cuda_edge_detection(Mat * image) {

	pixel * d_image;
	int elements = (*image).cols * (*image).rows;

	cudaMalloc((void**)&d_image, elements * sizeof(Mat));
	cudaMemcpy(d_image, image, elements * sizeof(Mat), cudaMemcpyHostToDevice);
	kernel_grayscale << <64, 64 >> >(d_image);

	cudaFree(d_image);

}