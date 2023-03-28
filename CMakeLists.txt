cmake_minimum_required (VERSION 3.22)

project(StarkGate VERSION 0.1.0)

include(CMakeLists_common.txt)

include("src/starkware/starknet/compiler/starknet_cmake_rules.cmake")

add_subdirectory(src)
