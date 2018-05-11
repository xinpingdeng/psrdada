# psrdada
The original version is from https://git.code.sf.net/p/psrdada/code, I make it work with nvidia/cuda:9.1-cudnn7-devel-ubuntu16.04 docker container.

I added "#include <cuda_fp16.h>" at the top of girt/src/mac_device.hpp. To compile it from source in nvidia/cuda:9.1-cudnn7-devel-ubuntu16.04 docker container, we also need to specify --with-cuda-include-dir and --with-cuda-lib-dir. We also need to use CFLAGS=-O3 compiler option. 
