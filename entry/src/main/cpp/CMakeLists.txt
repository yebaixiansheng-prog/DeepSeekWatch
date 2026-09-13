cmake_minimum_required(VERSION 3.5.0)
project(dswatch)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(entry SHARED
    napi_init.cpp
    keccak_core.cpp)

target_include_directories(entry PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# libace_napi.z.so 提供 napi 接口
target_link_libraries(entry PUBLIC libace_napi.z.so)
