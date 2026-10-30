// NPU-only build shim for the llama.cpp OpenVINO backend.
//
// Replaces <CL/cl.h> and <openvino/runtime/intel_gpu/ocl/ocl.hpp>, which pull in the
// Khronos `CL/cl2.hpp` C++ bindings that are not available in this environment.
//
// Every symbol below belongs to the *GPU* remote-context / USM zero-copy path
// (`has_prefix(device_name, "GPU")`, `GGML_ASSERT(ggml_openvino_is_gpu())`).
// The NPU path never touches it -- upstream itself notes "remote tensor is not used
// for NPU yet" (ggml-openvino-extra.cpp). So these definitions exist purely to let
// the GPU code keep compiling; calling any of them is a hard error by design.
//
// The NPU Level Zero header (<openvino/runtime/intel_npu/level_zero/level_zero.hpp>)
// needs no external headers and is left untouched.
#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>

#include <openvino/core/shape.hpp>
#include <openvino/runtime/common.hpp>
#include <openvino/runtime/core.hpp>
#include <openvino/runtime/remote_context.hpp>
#include <openvino/runtime/tensor.hpp>

// ---------------------------------------------------------------------------
// Minimal Khronos OpenCL C declarations (GPU path only, never linked against OpenCL)
// ---------------------------------------------------------------------------
#ifndef GGML_OV_CL_SHIM_TYPES
#define GGML_OV_CL_SHIM_TYPES

#ifndef CL_API_CALL
#define CL_API_CALL
#endif

using cl_int = int;
using cl_uint = unsigned int;
using cl_ulong = unsigned long long;
using cl_bool = cl_uint;
// distinct opaque handle types (matching the real OpenCL headers' mutual incompatibility)
struct _cl_context;
struct _cl_command_queue;
struct _cl_device_id;
struct _cl_platform_id;
struct _cl_event;
using cl_context = _cl_context *;
using cl_command_queue = _cl_command_queue *;
using cl_device_id = _cl_device_id *;
using cl_platform_id = _cl_platform_id *;
using cl_event = _cl_event *;
using cl_queue_properties = cl_ulong;

enum : cl_int { CL_SUCCESS = 0, CL_OUT_OF_RESOURCES = -5, CL_INVALID_VALUE = -30 };
enum : cl_int { CL_TRUE = 1, CL_FALSE = 0 };
enum : cl_int { CL_CONTEXT_DEVICES = 0x1040 };
enum : cl_int { CL_DEVICE_PLATFORM = 0x1030, CL_DEVICE_MAX_MEM_ALLOC_SIZE = 0x1028 };
enum : cl_ulong { CL_QUEUE_PROPERTIES = 1ULL << 0, CL_QUEUE_PROFILING_ENABLE = 1ULL << 1 };

namespace ggml_ov_cl_shim_detail {

[[noreturn]] inline void gpu_path_unavailable(const char * what) {
    throw std::runtime_error(std::string("llama.cpp OpenVINO NPU-only build: OpenCL/GPU path is disabled (") + what +
                             ")");
}

}  // namespace ggml_ov_cl_shim_detail

inline cl_int clGetContextInfo(cl_context, cl_int, size_t, void * param_value, size_t * param_value_size_ret) {
    ggml_ov_cl_shim_detail::gpu_path_unavailable("clGetContextInfo");
}
inline cl_int clGetDeviceInfo(cl_device_id, cl_int, size_t, void * param_value, size_t * param_value_size_ret) {
    ggml_ov_cl_shim_detail::gpu_path_unavailable("clGetDeviceInfo");
}
inline void * clGetExtensionFunctionAddressForPlatform(cl_platform_id, const char *) {
    ggml_ov_cl_shim_detail::gpu_path_unavailable("clGetExtensionFunctionAddressForPlatform");
}
inline cl_command_queue clCreateCommandQueueWithProperties(cl_context, cl_device_id, const cl_queue_properties *,
                                                           cl_int * errcode_ret) {
    ggml_ov_cl_shim_detail::gpu_path_unavailable("clCreateCommandQueueWithProperties");
}
inline cl_int clReleaseCommandQueue(cl_command_queue) {
    ggml_ov_cl_shim_detail::gpu_path_unavailable("clReleaseCommandQueue");
}
inline cl_int clFinish(cl_command_queue) {
    ggml_ov_cl_shim_detail::gpu_path_unavailable("clFinish");
}

#endif  // GGML_OV_CL_SHIM_TYPES

// ---------------------------------------------------------------------------
// ov::intel_gpu::ocl::{ClContext,USMTensor} -- same shapes as the real headers,
// every entry point aborts instead of touching OpenCL.
// ---------------------------------------------------------------------------
namespace ov {
namespace intel_gpu {
namespace ocl {

class USMTensor;

class ClContext : public ov::RemoteContext {
public:
    ClContext() = default;

    ClContext(ov::Core & /*core*/, cl_context /*ctx*/, int /*ctx_device_id*/ = 0) {
        ggml_ov_cl_shim_detail::gpu_path_unavailable("ClContext(Core&, cl_context)");
    }

    ClContext(ov::Core & /*core*/, cl_command_queue /*queue*/) {
        ggml_ov_cl_shim_detail::gpu_path_unavailable("ClContext(Core&, cl_command_queue)");
    }

    cl_context get() {
        ggml_ov_cl_shim_detail::gpu_path_unavailable("ClContext::get");
    }

    operator cl_context() {
        return get();
    }

    USMTensor create_tensor(const ov::element::Type & /*type*/, const ov::Shape & /*shape*/, void * /*host_ptr*/);

    USMTensor create_usm_device_tensor(const ov::element::Type & /*type*/, const ov::Shape & /*shape*/);
};

class USMTensor : public ov::Tensor {
public:
    USMTensor() = default;
    USMTensor(USMTensor && other) noexcept : ov::Tensor(std::move(other)) {}
    USMTensor & operator=(USMTensor && other) noexcept {
        ov::Tensor::operator=(std::move(other));
        return *this;
    }

    void * get() const {
        return const_cast<void *>(ov::Tensor::data());
    }
};

inline USMTensor ClContext::create_tensor(const ov::element::Type & /*type*/, const ov::Shape & /*shape*/,
                                         void * /*host_ptr*/) {
    ggml_ov_cl_shim_detail::gpu_path_unavailable("ClContext::create_tensor");
}

inline USMTensor ClContext::create_usm_device_tensor(const ov::element::Type & /*type*/, const ov::Shape & /*shape*/) {
    ggml_ov_cl_shim_detail::gpu_path_unavailable("ClContext::create_usm_device_tensor");
}

}  // namespace ocl
}  // namespace intel_gpu
}  // namespace ov
