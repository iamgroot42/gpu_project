#include <bits/stdc++.h>
#include <IL/il.h>
#include <IL/ilu.h>

#define BLOCK_SIZE 32
#define HYPERm 2
#define HYPERk 4
#define LAMBDA 2.0

#define FLOAT_MAX 1e18 + 0.0

using namespace std;


struct Pixel{
	int pixel_value, hard_constraint, height;
	float neighbor_capacities[10]; //Stored in row major form, followed by source and sink
	float neighbor_flows[10];
	float excess;
	Pixel(){
		this -> hard_constraint = 0;
		this -> height = 0;
		this -> excess = 0;
	}
};

struct Terminal{
	float excess, capacity, flow;
	int height;
	int numNeighbours;
	int *neighbors;
	Terminal(){
		this -> height = 0;
		this -> excess = 0;
	}
};

__device__ float B_function(int x, int y)
{
	return 100.0 / abs(x + 1  - y);
}

__device__ float R_function(int x, bool is_object)
{
	return LAMBDA + is_object * 1.0;
}

void saveImage(const char* filename, int width, int height, unsigned char * bitmap){
	ILuint imageID = ilGenImage();
	ilBindImage(imageID);
	ilTexImage(width, height, 0, 1, IL_LUMINANCE, IL_UNSIGNED_BYTE, bitmap);
	iluFlipImage();
	ilEnable(IL_FILE_OVERWRITE);
	ilSave(IL_PNG, filename);
	fprintf(stderr, "Image saved as: %s\n", filename);
}

ILuint loadImage(const char *filename, unsigned char ** bitmap, int &width, int &height){
	ILuint imageID = ilGenImage();
	ilBindImage(imageID);
	ILboolean success = ilLoadImage(filename);
	if (!success) return 0;

	width = ilGetInteger(IL_IMAGE_WIDTH);
	height = ilGetInteger(IL_IMAGE_HEIGHT);
	printf("Width: %d\t Height: %d\n", width, height);
	*bitmap = ilGetData();
	return imageID;
}

pair<int, int> readConstraints(char* hard_constraints, const char* objectFile, const char* backgroundFile, int height, int width)
{
	ifstream f1(objectFile);
	int x, y, c1, c2;

	while (f1 >> x >> y)
	{
		hard_constraints[x * height + y] = 1;
		c1++;
	}
	f1.close();

	ifstream f2(backgroundFile);

	while (f2 >> x >> y)
	{
		hard_constraints[x * height + y] = 2;
		c2++;
	}
	f2.close();

	return make_pair(c1, c2);
}

__global__ void initNeighbors(Pixel *image_graph, unsigned char* raw_image, int height, int width, char* hard_constraints)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x + 1;
	int j = threadIdx.y + blockDim.y * blockIdx.y + 1;

	if (i <= height && j <= width){
		image_graph[i * width + j].pixel_value = raw_image[(i - 1) * width + j - 1];

		// Row major traversal of neighbors of a pixel (i,j)
		int x_offsets[] = {-1, -1, -1, 0, 0, 1, 1, 1};
		int y_offsets[] = {-1, 0, 1, -1, 1, -1, 0, 1};
		float edge_weight = 0;
		int dest_x, dest_y;

		for(int k = 0; k < 8; k++){
			dest_x = i + x_offsets[k];
			dest_y = j + y_offsets[k];
			if (dest_x <= height && dest_y <= width)
			{
				edge_weight = B_function(image_graph[i * width + j].pixel_value, image_graph[dest_x * width + dest_y].pixel_value);
				image_graph[i * width + j].neighbor_capacities[k] = edge_weight;
				image_graph[i * width + j].neighbor_flows[k] = 0;
			}
		}
		
		char constraint = hard_constraints[(i - 1) * width + (j - 1)];
		image_graph[i * width + j].neighbor_flows[8] = 0;
		image_graph[i * width + j].neighbor_flows[9] = 0;
		// Default
		if(constraint == 0){
			image_graph[i * width + j].neighbor_capacities[8] = R_function(image_graph[i * width + j].pixel_value, false);
			image_graph[i * width + j].neighbor_capacities[9] = R_function(image_graph[i * width + j].pixel_value, true);
		}
		// Object
		else if(constraint == 1){
			image_graph[i * width + j].excess = FLOAT_MAX;
			image_graph[i * width + j].neighbor_capacities[8] = FLOAT_MAX;
			image_graph[i * width + j].neighbor_capacities[9] = 0;
		}
		// Background
		else{
			image_graph[i * width + j].neighbor_capacities[8] = 0;
			image_graph[i * width + j].neighbor_capacities[9] = FLOAT_MAX;
		}

		__syncthreads();
	}
}

__global__ void push(Pixel *image_graph, float *F, Terminal *source, Terminal *sink, int height, int width, int *convergence_flag){
	int i = (threadIdx.x + blockIdx.x * blockDim.x) + 1;
	int j = (threadIdx.y + blockDim.y * blockIdx.y) + 1;

	if (i <= height && j <= width)
	{
		int x_offsets[] = {-1, -1, -1, 0, 0, 1, 1, 1};
		int y_offsets[] = {-1, 0, 1, -1, 1, -1, 0, 1};
		int thread_flag = 0, dest_x, dest_y;

		for(int l = 0; l < 8; l++){
			dest_x = i + x_offsets[l];
			dest_y = j + y_offsets[l];
			if (dest_x <= height && dest_y <= width)
			{
				// printf("Entered outer\n");
				if(image_graph[dest_x * width + dest_y].height + 1 == image_graph[i * width + j].height)
				{
					// printf("Entered\n");
					float flow = min(image_graph[i * width + j].neighbor_capacities[l] - \
						image_graph[i * width + j].neighbor_flows[l], image_graph[i * width + j].excess);
					atomicAdd(&(image_graph[i * width + j].excess), -flow) ;
					atomicAdd(&(image_graph[dest_x * width + dest_y].excess), flow) ;
					atomicAdd(&(image_graph[i * width + j].neighbor_flows[l]), flow) ;
					atomicAdd(&(image_graph[dest_x * width + dest_y].neighbor_flows[7 - l]), -flow) ;
					thread_flag = 1;
				}
			}
		}

		float flow = min(image_graph[i * width + j].neighbor_capacities[9] - image_graph[i * width + j].neighbor_flows[9], image_graph[i * width + j].excess);
		atomicAdd(&(image_graph[i * width + j].excess), -flow) ;
		atomicAdd(&(sink -> excess), flow) ;
		atomicAdd(&(image_graph[i * width + j].neighbor_flows[9]), flow) ;
		// atomicAdd(&(image_graph[dest_x * width + dest_y].neighbor_flows[7 - l]), -flow) ;
		atomicOr(convergence_flag, thread_flag);
		// if (thread_flag)
		// 	printf("Flow pushed to at least one pixel.\n");
		// printf("%d ", *convergence_flag);
	}
}

__global__ void localRelabel(Pixel* image_graph, Terminal *source, Terminal *sink, int height, int width)
{
	int i = (threadIdx.x + blockIdx.x * blockDim.x) + 1;
	int j = (threadIdx.y + blockDim.y * blockIdx.y) + 1;

	if (i <= height && j <= width)
	{
		int x_offsets[] = {-1, -1, -1, 0, 0, 1, 1, 1};
		int y_offsets[] = {-1, 0, 1, -1, 1, -1, 0, 1};
		int dest_x, dest_y, min_height = image_graph[i * width + j].height;

		for(int l = 0; l < 8; l++){
			dest_x = i + x_offsets[l];
			dest_y = j + y_offsets[l];
			if (dest_x <= height && dest_y <= width)
				if (image_graph[i * width + j].neighbor_capacities[l] > image_graph[i * width + j].neighbor_flows[l])
					min_height = min(min_height, image_graph[dest_x * width + dest_y].height);
		}

		// // Source
		// if (source -> capacity > source -> flow)
		// 	min_height = min(min_height, source -> height);

		// // Sink
		// if (sink -> capacity > sink -> flow)
		// 	min_height = min(min_height, sink -> height);

		if (min_height < 1)
			min_height = 1;
		image_graph[i * width + j].height = min_height + 1;
		// printf("Setting height %d for pixel %d\n", min_height, i * width + j);
	}
}

__global__ void globalRelabel(Pixel *image_graph, int height, int width, int iteration)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x + 1;
	int j = threadIdx.y + blockDim.y * blockIdx.y + 1;

	if (i <= height && j <= width)
	{
		int x_offsets[] = {-1, -1, -1, 0, 0, 1, 1, 1};
		int y_offsets[] = {-1, 0, 1, -1, 1, -1, 0, 1};
		int dest_x, dest_y;

		if(iteration == 1)
			for (int l = 0; l < 8; l++)
			{
				dest_x = i + x_offsets[l];
				dest_y = j + y_offsets[l];
				if (dest_x <= height && dest_y <= width)
					if (image_graph[i * width + j].neighbor_capacities[l] > image_graph[i * width + j].neighbor_flows[l])
						image_graph[dest_x * width + dest_y].height = 1;
			}
		else{

			bool satisfied = false;

			for(int l = 0; l < 8; l++)
			{
				dest_x = i + x_offsets[l];
				dest_y = j + y_offsets[l];
				if (dest_x <= height && dest_y <= width)
					if(image_graph[dest_x * height + dest_y].height == iteration)
					{
						satisfied = true;
						break;
					}
			}

			if(satisfied)
				image_graph[i * width + j].height = iteration + 1;
		}
	}
}

__global__ void markObject(Pixel *image_graph, int height, int width)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x + 1;
	int j = threadIdx.y + blockIdx.y * blockDim.y + 1;
	
	int x_offsets[] = {-1, -1, -1, 0, 0, 1, 1, 1};
        int y_offsets[] = {-1, 0, 1, -1, 1, -1, 0, 1};

	if (i <= height && j <= width){
		//for (int l = 0; l < 8; l++){
			//int des_x = i + x_offsets[l];
			//int des_y = j + y_offsets[l];
			if (image_graph[i * width + j].neighbor_flows[8] == image_graph[i * width + j].neighbor_capacities[8])
				printf("%d\n", (i-1) * width + (j-1));
		//}
	}
}

int main(int argc, char const *argv[])
{
	int width, height;
	int* convergence_flag = new int, *convergence_flag_gpu;
	*convergence_flag = 0;

	unsigned char *image, *cuda_image;
	char* constraints, *gpu_constraints;
	float *F_gpu;
	Pixel *image_graph, *cuda_image_graph;
	Terminal *source, *sink, *cuda_source, *cuda_sink;
	
	ilInit();

	ILuint image_id = loadImage(argv[1], &image, width, height);
	int pixel_memsize = (width + 1) * (height + 1) * sizeof(Pixel);
	if(image_id == 0) {fprintf(stderr, "Error while reading image... aborting.\n"); exit(0);}

	//Pixel graph with padding to avoid divergence in kernels for boundary pixels
	image_graph = (Pixel*)malloc(pixel_memsize);
	constraints = (char*)malloc(width * height * sizeof(char));
	source = new Terminal;
	sink = new Terminal;

	// Load constraints
	pair<int, int> p = readConstraints(constraints, argv[2], argv[3], height, width);

	// Source
	source -> capacity = FLOAT_MAX;
	source -> flow = FLOAT_MAX;
	source -> excess = FLOAT_MAX;
	source -> height = width * height - 1;

	// Sink
	sink -> capacity = FLOAT_MAX;
	sink -> flow = FLOAT_MAX;

	cudaMalloc((void**)&F_gpu, (width + 1) * (height + 1) * sizeof(float));
	cudaMalloc((void**)&convergence_flag_gpu, sizeof(int));
	cudaMalloc((void**)&cuda_image_graph, pixel_memsize);
	cudaMalloc((void**)&cuda_image, width * height * sizeof(unsigned char));
	cudaMalloc((void**)&cuda_source, sizeof(Terminal));
	cudaMalloc((void**)&cuda_sink, sizeof(Terminal));
	cudaMalloc((void**)&gpu_constraints, width * height * sizeof(char));

	//Set properties of source and sink nodes
	cudaMemcpy(cuda_image_graph, image_graph, pixel_memsize, cudaMemcpyHostToDevice);
	cudaMemcpy(cuda_image, image, width * height * sizeof(unsigned char), cudaMemcpyHostToDevice);
	cudaMemcpy(convergence_flag_gpu, convergence_flag, sizeof(int), cudaMemcpyHostToDevice);
	cudaMemcpy(cuda_source, source, sizeof(Terminal), cudaMemcpyHostToDevice);
	cudaMemcpy(cuda_sink, sink, sizeof(Terminal), cudaMemcpyHostToDevice);
	cudaMemcpy(gpu_constraints, constraints, width * height * sizeof(char), cudaMemcpyHostToDevice);


	dim3 threadsPerBlock(BLOCK_SIZE, BLOCK_SIZE);
	dim3 numBlocks((height % BLOCK_SIZE == 0 ? height / BLOCK_SIZE : height / BLOCK_SIZE + 1), (width % BLOCK_SIZE == 0 ? width / BLOCK_SIZE : width / BLOCK_SIZE + 1));

	// Load weights in graph using kernel call/host loops
	initNeighbors<<<numBlocks, threadsPerBlock>>>(cuda_image_graph, cuda_image, height, width, gpu_constraints);
	assert(cudaSuccess == cudaGetLastError());
	//printf("Initialized spatial weight values\n");

	// cudaMemcpy(source, cuda_source, sizeof(Terminal), cudaMemcpyDeviceToHost);
	// printf("Excess at source: %f\n", source -> excess);
	// printf("Flow of source: %f\n", source -> flow);
	// printf("Capacity of source: %f\n", source -> capacity);

	// cudaMemcpy(sink, cuda_sink, sizeof(Terminal), cudaMemcpyDeviceToHost);
	// printf("Excess at sink: %f\n", sink -> excess);
	// printf("Flow of sink: %f\n", sink -> flow);
	// printf("Capacity of sink: %f\n", sink -> capacity);
	int iteration = 1;

	while (iteration < 100)
	{
		for (int i = 0; i < HYPERk; i++)
			for (int j = 0; j < HYPERm; j++)
			{
				{
					push<<<numBlocks, threadsPerBlock>>>(cuda_image_graph, F_gpu, cuda_source, cuda_sink, height, width, convergence_flag_gpu);
					assert(cudaSuccess == cudaGetLastError());
				}
				localRelabel<<<numBlocks, threadsPerBlock>>>(cuda_image_graph, cuda_source, cuda_sink, height, width);
				assert(cudaSuccess == cudaGetLastError());
				cudaMemcpy(image_graph, cuda_image_graph, pixel_memsize, cudaMemcpyDeviceToHost);

				// for (int k = 0; k < width * height; i++)
				// 	if (image_graph[k].height > 0)
				// 		printf("%d ", image_graph[k].height);
			}
		if (iteration % 10 == 0)
		{
			globalRelabel<<<numBlocks, threadsPerBlock>>>(cuda_image_graph, height, width, iteration);
			assert(cudaSuccess == cudaGetLastError());
		}
		// printf("Completed iteration %d\n", iteration);
		cudaMemcpy(sink, cuda_sink, sizeof(Terminal), cudaMemcpyDeviceToHost);
		cudaMemcpy(source, cuda_source, sizeof(Terminal), cudaMemcpyDeviceToHost);
		// printf("Sink excess: %f\n", sink -> excess);
		// printf("Source excess: %f\n", source -> excess);
		iteration++;
	}
	// printf("Mark kernel called\n");
	markObject<<<numBlocks, threadsPerBlock>>>(cuda_image_graph, height, width);
	assert(cudaSuccess == cudaGetLastError());
	cudaDeviceSynchronize();
	return 0;
}

