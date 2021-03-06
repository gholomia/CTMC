#include <iostream>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <math.h>
// #include <chrono>
// #include <math_functions.h>
#include <bitmap_image.hpp>

#define errorHandler(stmt)																					\
	do {																									\
		cudaError_t err = stmt;																				\
		if (err != cudaSuccess) {																			\
			printf("[ERROR] Failed to run stmt %d, error body: %s\n", __LINE__, cudaGetErrorString(err));	\
			return -1; }																 					\
	} while (0)																								\

#define M_PI 3.14159265
#define BLOCK_SIZE_X 32
#define BLOCK_SIZE_Y 32
#define BLOCK_SIZE 1024

using namespace std;

int initiate_parallel_template_matching(bitmap_image, bitmap_image);
void initiate_serial_template_matching(bitmap_image, bitmap_image);
void device_query();
void extract_array(unsigned char*, unsigned int, bitmap_image);
bitmap_image rotate_ninty_anticlockwise(bitmap_image image, unsigned int width, unsigned int height);
int get_number_of_occurances(int * arr, unsigned int size);

/*
*	CUDA Kernel to compute SADs
*/
__global__ void
compute_sad_array_kernel(int* sad_array, unsigned char* image, unsigned char* kernel, int sad_array_size, int image_width, int image_height, int kernel_width, int kernel_height, int kernel_size)
{
	int row = blockIdx.y * blockDim.y + threadIdx.y;
	int col = blockIdx.x * blockDim.x + threadIdx.x;
	int SAD_RESULT = 0;

	if (row < image_height && col < image_width) {
		#pragma unroll 4
		for (int v_row = 0; v_row < kernel_height; v_row++) {
			#pragma unroll 4
			for (int v_col = 0; v_col < kernel_width; v_col++) {
				int m_r = (int)(image[((row + v_row) * image_width + (col + v_col)) * 3 + 0]);
				int m_g = (int)(image[((row + v_row) * image_width + (col + v_col)) * 3 + 1]);
				int m_b = (int)(image[((row + v_row) * image_width + (col + v_col)) * 3 + 2]);
				int t_r = (int)(kernel[(v_row * kernel_width + v_col) * 3 + 0]);
				int t_g = (int)(kernel[(v_row * kernel_width + v_col) * 3 + 1]);
				int t_b = (int)(kernel[(v_row * kernel_width + v_col) * 3 + 2]);
				int error = abs(m_r - t_r) + abs(m_g - t_g) + abs(m_b - t_b);
				SAD_RESULT += error;
			}
		}


		int NORMALIZED_SAD = (int)(SAD_RESULT / (float)kernel_size);

		__syncthreads();

		int my_index_in_sad_array = row * image_width + col;
		if (my_index_in_sad_array < sad_array_size) {
			sad_array[my_index_in_sad_array] = NORMALIZED_SAD;
		}
	}
}


/*
*	CUDA Kernel to compute the minimum number in an array
*/
__global__ void
findMinInArrayKernel(int* mse_array, int mse_array_size, int* min_mse, int* mutex)
{
	unsigned int tId = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int stride = gridDim.x * blockDim.x;
	unsigned int offset = 0;

	__shared__ int cache[BLOCK_SIZE];

	int temp = 5000;
	while (tId + offset < mse_array_size) {
		temp = fminf(temp, mse_array[tId + offset]);
		offset += stride;
	}

	cache[threadIdx.x] = temp;

	__syncthreads();

	unsigned int i = blockDim.x / 2;
	while (i != 0) {
		if (threadIdx.x < i) {
			cache[threadIdx.x] = fminf(cache[threadIdx.x], cache[threadIdx.x + i]);
		}

		__syncthreads();
		i /= 2;
	}

	// Update global min for each block
	if (threadIdx.x == 0) {

		// Lock
		while (atomicCAS(mutex, 0, 1) != 0);

		*min_mse = fminf(*min_mse, cache[0]);

		// Unlock
		atomicExch(mutex, 0);
	}
}

__global__ void
findNumberofOccurances(int* mse_array, int* min_mse, int* mutex, int* num_occurances)
{
	unsigned int tId = threadIdx.x + blockIdx.x * blockDim.x;

	__shared__ int cache[BLOCK_SIZE];

	cache[threadIdx.x] = mse_array[tId];

	if (threadIdx.x == 0)
		cache[0] = 0;

	__syncthreads();

	if (cache[threadIdx.x] == *min_mse)
		atomicAdd(&cache[0], 1);


	__syncthreads();
	// Update global occurance for each block
	if (threadIdx.x == 0) {

		// Lock
		while (atomicCAS(mutex, 0, 1) != 0);

		atomicAdd(num_occurances, cache[0]);

		// Unlock
		atomicExch(mutex, 0);
	}
}

int main(int argc, char* argv[])
{

	// Parse args
	for (int count = 0; count < argc; count += 2) {
		
		bitmap_image main_image(argv[count]);
		bitmap_image template_image(argv[count + 1]);

		// Initiate template matching
		initiate_parallel_template_matching(main_image, template_image);
	}

	// bitmap_image rotated_template;
	// rotated_template = rotate_clockwise(template_image, template_image.width(), template_image.height());
	system("pause");
	return 0;
}

int	initiate_parallel_template_matching(bitmap_image main_image, bitmap_image template_image)
{
	// Get sizes
	int main_width = main_image.width();
	int main_height = main_image.height();
	int main_size = main_width * main_height;
	int template_width = template_image.width();
	int template_height = template_image.height();
	int template_size = template_width * template_height;
	int height_difference = main_height - template_height;
	int width_difference = main_width - template_width;
	int mse_array_size = (height_difference + 1) * (width_difference + 1);

	// Define host pointers
	unsigned char* h_main_image;
	unsigned char* h_template_image;
	int* h_mse_array;
	int* h_min_mse;
	int* h_num_occurances;
	int* h_template_image_rotated;

	// Define device pointers
	unsigned char* d_main_image;
	unsigned char* d_template_image;
	int* d_mse_array;
	int* d_min_mse;
	int* d_num_occurances;
	int* d_mutex;

	// CUDA time handling
	cudaEvent_t start;
	cudaEvent_t stop;
	float elapsed_time = 0.0f;

	// Host allocation

	/*
	Extract Matrices
	*/



	h_main_image = new unsigned char[3 * main_size];

	for (int col = 0; col < main_width; col++) {
		for (int row = 0; row < main_height; row++) {
			rgb_t colors;

			main_image.get_pixel(col, row, colors);
			h_main_image[(row * main_width + col) * 3 + 0] = colors.red;
			h_main_image[(row * main_width + col) * 3 + 1] = colors.green;
			h_main_image[(row * main_width + col) * 3 + 2] = colors.blue;
		}
	}

	h_template_image = new unsigned char[3 * template_size];

	for (int col = 0; col < template_width; col++) {
		for (int row = 0; row < template_height; row++) {
			rgb_t colors;

			template_image.get_pixel(col, row, colors);
			h_template_image[(row * template_width + col) * 3 + 0] = colors.red;
			h_template_image[(row * template_width + col) * 3 + 1] = colors.green;
			h_template_image[(row * template_width + col) * 3 + 2] = colors.blue;
		}
	}

	/*
	*************************
	*/

	h_mse_array = new int[mse_array_size];
	h_min_mse = new int[1];
	h_num_occurances = new int[1];

	// Device allocation
	errorHandler(cudaMalloc((void **)&d_main_image, 3 * main_size * sizeof(unsigned char)));
	errorHandler(cudaMalloc((void **)&d_template_image, 3 * template_size * sizeof(unsigned char)));
	errorHandler(cudaMalloc((void **)&d_mse_array, mse_array_size * sizeof(int)));
	errorHandler(cudaMalloc((void **)&d_min_mse, sizeof(int)));
	errorHandler(cudaMalloc((void **)&d_mutex, sizeof(int)));
	errorHandler(cudaMalloc((void **)&d_num_occurances, sizeof(int)));
	errorHandler(cudaMemset(d_min_mse, 20, sizeof(int)));
	errorHandler(cudaMemset(d_mutex, 0, sizeof(int)));
	errorHandler(cudaMemset(d_num_occurances, 0, sizeof(int)));
	errorHandler(cudaMemcpy(d_main_image, h_main_image, 3 * main_size * sizeof(unsigned char), cudaMemcpyHostToDevice));
	errorHandler(cudaMemcpy(d_template_image, h_template_image, 3 * template_size * sizeof(unsigned char), cudaMemcpyHostToDevice));

	errorHandler(cudaEventCreate(&start));
	errorHandler(cudaEventCreate(&stop));
	errorHandler(cudaEventRecord(start));

	dim3 grid_dimensions((unsigned int)ceil((float)(main_width) / BLOCK_SIZE_X), (unsigned int)ceil((float)(main_height) / BLOCK_SIZE_Y), 1);
	dim3 block_dimensions(BLOCK_SIZE_X, BLOCK_SIZE_Y, 1);
	compute_sad_array_kernel << <grid_dimensions, block_dimensions >> > (d_mse_array, d_main_image, d_template_image, mse_array_size, main_width, main_height, template_width, template_height, template_size);

	dim3 grid_dimensions_2((unsigned int)ceil((float)mse_array_size) / BLOCK_SIZE, 1, 1);
	dim3 block_dimensions_2(BLOCK_SIZE, 1, 1);
	findMinInArrayKernel << <grid_dimensions_2, block_dimensions_2 >> > (d_mse_array, mse_array_size, d_min_mse, d_mutex);

	findNumberofOccurances << < grid_dimensions_2, block_dimensions_2 >> > (d_mse_array, d_min_mse, d_mutex, d_num_occurances);
	errorHandler(cudaGetLastError());
	errorHandler(cudaEventRecord(stop, NULL));
	errorHandler(cudaEventSynchronize(stop));
	errorHandler(cudaEventElapsedTime(&elapsed_time, start, stop));
	errorHandler(cudaMemcpy(h_mse_array, d_mse_array, mse_array_size * sizeof(int), cudaMemcpyDeviceToHost));
	errorHandler(cudaMemcpy(h_min_mse, d_min_mse, sizeof(int), cudaMemcpyDeviceToHost));
	errorHandler(cudaMemcpy(h_num_occurances, d_num_occurances, sizeof(int), cudaMemcpyDeviceToHost));

	wcout << "[[[ Parallel Computation Results ]]] " << endl << endl;
	wcout << "Elapsed time in msec = " << (int)(elapsed_time) << endl;
	wcout << "[Main Image Dimensions]: " << main_width << "*" << main_height << endl;
	wcout << "[Template Image Dimensions]: " << template_width << "*" << template_height << endl;
	wcout << "[MSE Array Size]:	" << mse_array_size << endl;
	// get_number_of_occurances(h_mse_array, mse_array_size);
	wcout << "[Found Minimum]:  " << *h_min_mse << endl;
	wcout << "[Number of Occurances]: " << *h_num_occurances << endl;
	errorHandler(cudaFree(d_main_image));
	errorHandler(cudaFree(d_template_image));
	free(h_main_image);
	free(h_template_image);
	return EXIT_SUCCESS;
}

void initiate_serial_template_matching(bitmap_image mainImage, bitmap_image templateImage)
{
	std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();
	int main_width = mainImage.width();
	int main_height = mainImage.height();
	int template_width = templateImage.width();
	int template_height = templateImage.height();

	int templateSize = template_height * template_width;

	int THRESHOLD = 20;
	unsigned int NUM_OCCURANCES = 0;
	int FOUND_MINIMUM = 100000;
	int NUM_OF_ZEROS = 0;

	wcout << "[[[ Initiated Serial Template Matching ]]] " << endl;

	for (int col = 0; col < main_width - template_width; col++) {
		for (int row = 0; row < main_height - template_height; row++) {

			int SUM_OF_ABSOLUTE_DEVIATIONS = 0;

			for (int j = 0; j < template_width; j++) {
				for (int i = 0; i < template_height; i++) {

					int mRow = row + i;
					int mCol = col + j;

					rgb_t m_color;
					rgb_t t_color;

					mainImage.get_pixel(mCol, mRow, m_color);
					templateImage.get_pixel(j, i, t_color);

					SUM_OF_ABSOLUTE_DEVIATIONS += abs(m_color.red - t_color.red)
												+ abs(m_color.green - t_color.green)
												+ abs(m_color.blue - t_color.blue);

				}
			}

			int NORMALIZED_SAD = (int)(SUM_OF_ABSOLUTE_DEVIATIONS / (float)templateSize);

			if (NORMALIZED_SAD < THRESHOLD) {
				NUM_OCCURANCES++;
			}

			if (NORMALIZED_SAD < FOUND_MINIMUM) {
				FOUND_MINIMUM = (int)NORMALIZED_SAD;
			}

			if (NORMALIZED_SAD == 0)
				NUM_OF_ZEROS++;

		}
	}

	std::chrono::steady_clock::time_point end = std::chrono::steady_clock::now();
	wcout << "[[[ Serial Computation Results ]]] " << endl << endl;
	wcout << "Elapsed time in msec = " << chrono::duration_cast<std::chrono::milliseconds> (end - begin).count() << endl;
	wcout << "[Main Image Dimensions]: " << main_width << "*" << main_height << endl;
	wcout << "[Template Image Dimensions]: " << template_width << "*" << template_height << endl;
	wcout << "[Found Minimum]:  " << FOUND_MINIMUM << endl;
	wcout << "[Number of Occurances]: " << NUM_OCCURANCES << endl;
}

void device_query()
{
	const int kb = 1024;
	const int mb = kb * kb;
	wcout << "NBody.GPU" << endl << "=========" << endl << endl;

	wcout << "CUDA version:   v" << CUDART_VERSION << endl;

	int devCount;
	cudaGetDeviceCount(&devCount);
	wcout << "CUDA Devices: " << endl << endl;

	for (int i = 0; i < devCount; ++i)
	{
		cudaDeviceProp props;
		cudaGetDeviceProperties(&props, i);
		wcout << i << ": " << props.name << ": " << props.major << "." << props.minor << endl;
		wcout << "  Global memory:   " << props.totalGlobalMem / mb << "mb" << endl;
		wcout << "  Shared memory:   " << props.sharedMemPerBlock / kb << "kb" << endl;
		wcout << "  Constant memory: " << props.totalConstMem / kb << "kb" << endl;
		wcout << "  Block registers: " << props.regsPerBlock << endl << endl;

		wcout << "  Warp size:         " << props.warpSize << endl;
		wcout << "  Threads per block: " << props.maxThreadsPerBlock << endl;
		wcout << "  Max block dimensions: [ " << props.maxThreadsDim[0] << ", " << props.maxThreadsDim[1] << ", " << props.maxThreadsDim[2] << " ]" << endl;
		wcout << "  Max grid dimensions:  [ " << props.maxGridSize[0] << ", " << props.maxGridSize[1] << ", " << props.maxGridSize[2] << " ]" << endl;
		wcout << "  Concurrent Kernels:		" << props.concurrentKernels;

		wcout << endl;
	}
}

void extract_array(unsigned char* pixels, unsigned int pixels_size, bitmap_image image)
{
	int image_width = image.width();
	int image_height = image.height();

	pixels = new unsigned char[3 * pixels_size];

	for (int col = 0; col < image_width; col++) {
		for (int row = 0; row < image_height; row++) {
			rgb_t colors;

			image.get_pixel(col, row, colors);
			pixels[(row * image_width + col) * 3 + 0] = colors.red;
			pixels[(row * image_width + col) * 3 + 1] = colors.green;
			pixels[(row * image_width + col) * 3 + 2] = colors.blue;
		}
	}

}

int get_number_of_occurances(int * arr, unsigned int size)
{
	int min = arr[0];
	int num_of_occurs = 0;
	ofstream filemy;
	filemy.open("output.txt");

	for (unsigned int i = 0; i < size; i++) {
		filemy << arr[i] << "\n";
		if (arr[i] < min) {
			num_of_occurs = 1;
			min = arr[i];
		}

		if (arr[i] == min)
			num_of_occurs++;
	}

	wcout << "[Found Minimum]:  " << min << endl;
	wcout << "[Number of Occurances]: " << num_of_occurs << endl;

	return num_of_occurs;
}

bitmap_image rotate_ninty_anticlockwise(bitmap_image image, unsigned int width, unsigned int height)
{
	bitmap_image result(height, width);
	for (unsigned int x = 0; x < width; x++) {
		for (unsigned int y = 0; y < (height + 1) / 2; y++) {
			rgb_t pixelColor;

			image.get_pixel(x, y, pixelColor);
			result.set_pixel(y, height - 1 - x, pixelColor.red, pixelColor.green, pixelColor.blue);

			image.get_pixel(width - 1 - y, x, pixelColor);
			result.set_pixel(x, y, pixelColor.red, pixelColor.green, pixelColor.blue);

			image.get_pixel(width - 1 - x, width - 1 - y, pixelColor);
			result.set_pixel(width - 1 - y, x, pixelColor.red, pixelColor.green, pixelColor.blue);

			image.get_pixel(y, width - 1 - x, pixelColor);
			result.set_pixel(width - 1 - x, height - 1 - y, pixelColor.red, pixelColor.green, pixelColor.blue);
		}
	}
	return result;
}