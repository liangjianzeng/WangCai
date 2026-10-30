find_package(OpenVINO REQUIRED COMPONENTS Runtime Threading)

# The only consumer of the OpenCL host library is the GPU remote-context path, and
# ov_opencl_shim.hpp stubs every cl* entry point that path calls (they throw gpu_path_unavailable),
# so nothing here needs to link against OpenCL. `find_package(OpenCL REQUIRED)` meant the backend
# could not even be *configured* on a machine without an OpenCL SDK - which is every NPU-only
# machine; it built locally only because a CUDA toolkit had dropped an OpenCL.lib on the PATH.
# Found is still preferred: a build that restores the real Khronos headers gets the real library.
find_package(OpenCL QUIET)

message(STATUS "Found OpenVINO: ${OpenVINO_DIR} (found version \"${OpenVINO_VERSION}\")")
if (NOT OpenCL_FOUND)
    message(STATUS "OpenCL host library not found - building the OpenVINO backend without it "
                   "(the GPU remote-context path is stubbed; NPU and CPU builds are unaffected)")
endif()

file(GLOB_RECURSE GGML_HEADERS_OPENVINO "*.h" "*.hpp")
file(GLOB_RECURSE GGML_SOURCES_OPENVINO "*.cpp")

ggml_add_backend_library(ggml-openvino
    ${GGML_SOURCES_OPENVINO}
    ${GGML_HEADERS_OPENVINO}
)

target_link_libraries(ggml-openvino PRIVATE openvino::runtime openvino::threading)
if (OpenCL_FOUND)
    target_link_libraries(ggml-openvino PRIVATE OpenCL::OpenCL)
endif()

# the OpenVINO RTTI macros take one argument and leave __VA_ARGS__ empty, which -Wpedantic reports
if (CMAKE_CXX_COMPILER_ID MATCHES "Clang" OR CMAKE_CXX_COMPILER_ID STREQUAL "IntelLLVM")
    target_compile_options(ggml-openvino PRIVATE -Wno-gnu-zero-variadic-macro-arguments)
elseif (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    target_compile_options(ggml-openvino PRIVATE -Wno-pedantic)
endif()

if (WIN32)
    target_link_libraries(ggml-openvino PRIVATE psapi)
endif()

if (GGML_OPENVINO)
    if (CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
    elseif (CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "amd64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64")
    else()
        message(FATAL_ERROR "OpenVINO: OpenVINO toolkit supports x86-64 and arm64 but not ${CMAKE_SYSTEM_PROCESSOR}")
    endif()
endif()
