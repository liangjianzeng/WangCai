#include "utils.h"

#include "ggml-impl.h"
#include "ggml-openvino-extra.h"
#include "ggml-openvino.h"
#include "ggml-openvino/ggml-decoder.h"
#include "ggml.h"
#include "model-cache.h"
#include "openvino/frontend.h"
#include "openvino/input_model.h"

#include <algorithm>
#include <cctype>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <memory>
#include <atomic>
#include <openvino/core/any.hpp>
#include <openvino/core/graph_util.hpp>
#include <openvino/core/shape.hpp>
#include <openvino/core/type/float16.hpp>
#include <openvino/frontend/manager.hpp>
#include <openvino/openvino.hpp>
#include <openvino/runtime/compiled_model.hpp>
#include <openvino/runtime/infer_request.hpp>
#include "ov_opencl_shim.hpp"  // NPU-only build: GPU/CL remote-context path stubbed out
#include <openvino/runtime/intel_npu/properties.hpp>
#include <openvino/runtime/properties.hpp>
#include <openvino/runtime/tensor.hpp>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
// Runtime kill-switch for the decode level graphs, flipped automatically the first time a
// level graph dies with ZE_RESULT_ERROR_UNINITIALIZED (the device budget cannot hold the
// model's prefill + a level decode graph -- defect-7 family on the 2B omni model). The step
// is retried once on the full-ctx decode graph; same effect as
// GGML_OPENVINO_DISABLE_DECODE_LEVELS=1, discovered without the env.
static std::atomic<bool> g_decode_levels_disabled{false};
// For a KV cache input, return an ov::Tensor sized to n_kv (== attention_size
// for that layer) instead of the fully-allocated ctx_per_seq. Pre-conditions:
//   * non-static (CPU/GPU) backend, single sequence, seq_active_start == 0
//   * ggml KV layout is a contiguous [1, 1, ctx_per_seq, n_heads_kv*head_size]
//     so the first n_kv rows are the live prefix and shrinking the ctx axis
//     gives a valid tensor over the same host storage
//   * not an SWA layer (ring cache): once the window has wrapped the first
//     n_kv rows no longer contain the live prefix
// On any unmet pre-condition returns std::nullopt; the caller falls back to
// the full-size tensor.
std::optional<ov::Tensor> try_make_kv_sliced_tensor(const std::shared_ptr<GgmlOvDecoder> & ggml_decoder,
                                                    const std::string & name,
                                                    const ggml_tensor * ggml_tensor) {
    static const bool kv_slice_disabled = ggml_openvino_getenv_int("GGML_OPENVINO_DISABLE_KV_SLICE");
    if (kv_slice_disabled) {
        return std::nullopt;
    }
    if (ggml_decoder->is_static() || ggml_decoder->is_stateful()) {
        return std::nullopt;
    }
    if (ggml_tensor->op != GGML_OP_NONE || ggml_tensor->view_src != nullptr) {
        return std::nullopt;
    }
    const auto * op = ggml_decoder->get_tensor_used_op(ggml_tensor);
    if (!GgmlOvDecoder::is_kvcache(ggml_tensor, op)) {
        return std::nullopt;
    }

    const auto & compute_params = ggml_decoder->get_compute_params();
    if (compute_params.n_seq_active != 1 || compute_params.seq_active_start != 0) {
        return std::nullopt;
    }

    int layer;
    if (auto layer_opt = extract_layer_from_name(name); layer_opt.has_value()) {
        layer = layer_opt.value();
    } else {
        return std::nullopt;
    }

    const bool is_swa = ggml_decoder->is_swa_layer(layer);
    if (is_swa) {
        return std::nullopt;
    }
    const int ctx_per_seq = ggml_decoder->get_ctx_per_seq();
    const int n_kv = compute_params.attention_size;
    if (ctx_per_seq <= 0 || n_kv <= 0 || n_kv >= ctx_per_seq) {
        return std::nullopt;
    }

    ov::Shape full_shape = GgmlOvDecoder::get_shape(ggml_tensor);
    if (full_shape.size() != 4 || full_shape[0] != 1 || full_shape[1] != 1 ||
        static_cast<int>(full_shape[2]) != ctx_per_seq) {
        return std::nullopt;
    }

    ov::Shape sliced_shape = full_shape;
    sliced_shape[2] = static_cast<size_t>(n_kv);

    if (ggml_openvino_buffer_is_remote(ggml_tensor)) {
        auto remote_context = ggml_openvino_get_remote_context();
        auto gpu_context = remote_context->as<ov::intel_gpu::ocl::ClContext>();
        return gpu_context.create_tensor(ggml_decoder->get_ov_type(ggml_tensor), sliced_shape, ggml_tensor->data);
    }

    return ov::Tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), sliced_shape, ggml_tensor->data);
}

static uint64_t ggml_openvino_model_cache_extra_cfg(bool stateful, bool recurrent) {
    const char * manual_gqa_env = ggml_openvino_getenv_str("GGML_OPENVINO_MANUAL_GQA_ATTN");
    const bool manual_gqa_enabled = manual_gqa_env != nullptr ?
                                        ggml_openvino_getenv_int("GGML_OPENVINO_MANUAL_GQA_ATTN") > 0 :
                                        ggml_openvino_is_gpu();

    uint64_t extra_cfg = 1;  // Graph-ordinal port names (invalidate older disk-cache blobs).
    extra_cfg = extra_cfg * 131 + (stateful ? (recurrent ? 2u : 1u) : 0u);
    extra_cfg = extra_cfg * 131 + (ggml_openvino_reduce_compile_mem_enabled() ? 1u : 0u);
    extra_cfg = extra_cfg * 131 + (ggml_openvino_getenv_int("GGML_OPENVINO_DISABLE_KV_SLICE") ? 1u : 0u);
    extra_cfg = extra_cfg * 131 + (manual_gqa_enabled ? 1u : 0u);
    extra_cfg = extra_cfg * 131 + (ggml_openvino_getenv_int("GGML_OPENVINO_PROFILING") >= 2 ? 1u : 0u);
    // Multi-level static decode graphs (see decode_attention_level): the decode half's baked
    // attention span changed from the whole context to a per-level constant, so older
    // disk-cache blobs must not match.
    extra_cfg = extra_cfg * 131 + 3u;
    return extra_cfg;
}

std::map<std::string, std::shared_ptr<ov::Node>> get_weight_names(ggml_cgraph * cgraph) {
    std::map<std::string, std::shared_ptr<ov::Node>> names;
    for (const auto & name : GgmlOvDecoder::collect_weight_names(cgraph)) {
        names[name] = nullptr;
    }
    return names;
}

// A conservative, exact in-process key, evaluated only on a context-local cache
// miss. Include topology, layouts, op parameters, constant extra inputs and weight
// allocation identities. Never use a sampled weight hash or a graph name alone:
// different models can have identical topology. OV buffer IDs survive address reuse.
// GGML_OPENVINO_DUMP_BIN=<dir>: dump every graph output of a compute call to
// <dir>/<tag>_<seq>_<name>.bin (raw bytes) with a .txt sidecar holding shape and element type.
// Unlike GGML_OPENVINO_DEBUG_NODE this appends no Result nodes and only reads outputs the graph
// already produces, which matters because the NPU plugin aborts when extra outputs are added. It
// exists to compare two devices element by element: aggregate min/max/mean statistics hide
// single-row errors, and a single wrong row is exactly what a mis-selected chunk position looks like.
static void dump_ov_outputs_raw(const std::shared_ptr<ov::InferRequest> & infer_request,
                                const std::vector<std::string> & names,
                                const char * tag) {
    const char * dir = ggml_openvino_getenv_str("GGML_OPENVINO_DUMP_BIN");
    if (dir == nullptr || *dir == '\0') {
        return;
    }
    // Create the target directory: an ofstream against a missing directory fails silently, which
    // looks exactly like "the flag did nothing" - the failure mode this project can least afford.
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    if (ec) {
        static bool warned = false;
        if (!warned) {
            GGML_LOG_WARN("ggml-openvino: cannot create GGML_OPENVINO_DUMP_BIN directory '%s': %s\n", dir, ec.message().c_str());
            warned = true;
        }
        return;
    }
    static std::unordered_map<std::string, int> seq;
    for (size_t i = 0; i < names.size(); i++) {
        const auto tensor = infer_request->get_output_tensor(i);
        if (tensor.get_byte_size() == 0 || tensor.data() == nullptr) {
            continue;
        }
        std::string safe;
        for (char c : names[i]) {
            safe.push_back((std::isalnum((unsigned char) c) || c == '_' || c == '.') ? c : '_');
        }
        const std::string path = std::string(dir) + "\\" + tag + "_" + std::to_string(seq[names[i]]++) + "_" + safe;
        std::ofstream out(path + ".bin", std::ios::binary);
        if (!out.is_open()) {
            return;
        }
        out.write(static_cast<const char *>(tensor.data()), (std::streamsize) tensor.get_byte_size());
        out.close();
        std::ofstream meta(path + ".txt");
        if (meta.is_open()) {
            meta << names[i] << " shape=" << tensor.get_shape() << " type=" << tensor.get_element_type().get_type_name()
                 << '\n';
        }
    }
}

// Smallest 256*2^k attention span that covers n_kv, capped at ctx. llama.cpp pads its per-call
// KV span to a multiple of 256, so this discrete level set lets the static decode phase compile
// one fully-static graph per level (NPU graphs reject dynamic shapes, and baking the whole
// context makes every step attend the full span however few cells are filled -- decode at
// -c 2048 measured 294 ms/step vs 70 ms at -c 512 with ~40 filled cells).
static int decode_attention_level(int n_kv, int ctx) {
    if (n_kv <= 0) {
        return 0;
    }
    int level = 256;
    while (level < n_kv && level < ctx) {
        level *= 2;
    }
    return std::min(level, std::max(ctx, 1));
}

static std::string compiled_graph_key(const ggml_cgraph * graph,
                                      const GgmlOvDecoder & decoder,
                                      const std::string & device,
                                      int prefill_chunk_size = 0,
                                      bool disk_cache = false) {
    std::string key;
    auto append = [&key](const auto & value) {
        key.append(reinterpret_cast<const char *>(&value), sizeof(value));
    };
    auto append_string = [&](const std::string & value) {
        append(value.size());
        key.append(value);
    };
    append_string(device);
    append(decoder.is_static());
    append(decoder.is_stateful());
    append(prefill_chunk_size);
    bool has_weight_buffer_id = false;
    std::unordered_map<const ggml_tensor *, size_t> ids;
    std::function<void(const ggml_tensor *)> visit = [&](const ggml_tensor * tensor) {
        if (!tensor) {
            append(size_t(0));
            return;
        }
        auto inserted = ids.emplace(tensor, ids.size() + 1);
        append(inserted.first->second);
        if (!inserted.second) {
            return;
        }
        append_string(tensor->name);
        append(tensor->type);
        append(tensor->op);
        append(tensor->flags);
        append(tensor->ne);
        append(tensor->nb);
        append(tensor->op_params);
        append(tensor->view_offs);
        const auto * base = tensor->view_src ? tensor->view_src : tensor;
        const bool weight = base->buffer && base->buffer->usage == GGML_BACKEND_BUFFER_USAGE_WEIGHTS;
        append(weight);
        if (weight && !disk_cache) {
            const size_t buffer_id = ggml_backend_openvino_buffer_get_ctx_id(base->buffer);
            has_weight_buffer_id |= buffer_id != 0;
            append(buffer_id);
            append(tensor->data);
        }
        visit(tensor->view_src);
        for (const auto * src : tensor->src) {
            visit(src);
        }
    };
    append(graph->n_nodes);
    for (int i = 0; i < graph->n_nodes; ++i) {
        visit(graph->nodes[i]);
    }
    append(graph->n_leafs);
    for (int i = 0; i < graph->n_leafs; ++i) {
        visit(graph->leafs[i]);
    }
    for (const auto & input : decoder.get_model_extra_inputs()) {
        append_string(input.first);
        append_string(input.second.type.get_type_name());
        append(input.second.shape.size());
        for (auto dim : input.second.shape) {
            append(dim);
        }
        append(input.second.is_parameter);
        if (!input.second.is_parameter) {
            append(input.second.value);
        }
    }
    // Without an allocation generation, pointer reuse could select stale weights.
    // Such graphs still get private requests; they simply do not share compilation.
    return disk_cache || has_weight_buffer_id ? key : std::string{};
}

static std::string dynamic_graph_signature(const ggml_cgraph * graph,
                                           const GgmlOvDecoder & decoder,
                                           const ModelParams & params) {
    std::string key = "dynamic-1";
    auto append = [&key](const auto & value) {
        key.append(reinterpret_cast<const char *>(&value), sizeof(value));
    };
    auto append_string = [&](const std::string & value) {
        append(value.size());
        key.append(value);
    };
    graph_key graph_id(graph, true);
    append(graph_id.n_nodes);
    append(graph_id.n_leaves);
    append_string(graph_id.first_node_name);
    append_string(graph_id.last_node_name);
    for (const auto & name : graph_id.input_srcs) {
        append_string(name);
    }
    append(params.n_rs_slots);
    append(params.has_rs_rollback);
    append(params.mixed_rope_params);
    append(params.is_cacheless_attn);
    for (int layer : params.swa_layers) {
        append(layer);
    }
    for (const auto & [layer, heads] : params.n_heads_kv_per_layer) {
        append(layer);
        append(heads);
    }
    for (const auto & [name, input] : decoder.get_model_inputs()) {
        append_string(name);
        append_string(input.type.get_type_name());
    }
    for (const auto & [name, tensor] : decoder.get_model_outputs()) {
        append_string(name);
        append(tensor->type);
    }
    for (const auto & [name, input] : decoder.get_model_extra_inputs()) {
        append_string(name);
        append_string(input.type.get_type_name());
        append(input.is_parameter);
        if (!input.is_parameter) {
            append(input.value);
        }
    }
    return key;
}

static bool compiled_model_matches_graph(const ov::CompiledModel & model,
                                         const std::vector<std::string> & inputs,
                                         const std::vector<std::string> & outputs,
                                         const GgmlOvDecoder & decoder) {
    if (model.inputs().size() != inputs.size() || model.outputs().size() != outputs.size()) {
        return false;
    }
    const auto & graph_inputs = decoder.get_model_inputs();
    const auto & extra_inputs = decoder.get_model_extra_inputs();
    const auto & graph_outputs = decoder.get_model_outputs();
    for (size_t i = 0; i < inputs.size(); ++i) {
        const auto & port = model.input(i);
        auto graph_it = graph_inputs.find(inputs[i]);
        if (graph_it != graph_inputs.end()) {
            if (port.get_element_type() != graph_it->second.type ||
                !port.get_partial_shape().compatible(graph_it->second.shape)) {
                return false;
            }
            continue;
        }
        auto extra_it = extra_inputs.find(inputs[i]);
        if (extra_it == extra_inputs.end() || port.get_element_type() != extra_it->second.type ||
            !port.get_partial_shape().compatible(ov::PartialShape(extra_it->second.shape))) {
            return false;
        }
    }
    for (size_t i = 0; i < outputs.size(); ++i) {
        auto graph_it = graph_outputs.find(outputs[i]);
        if (graph_it == graph_outputs.end()) {
            if (outputs[i].compare(0, 8, "__debug_") != 0) {
                return false;
            }
            continue;
        }
        const auto & port = model.output(i);
        if (port.get_element_type() != GgmlOvDecoder::get_ov_type(graph_it->second) ||
            !port.get_partial_shape().compatible(ov::PartialShape(GgmlOvDecoder::get_shape(graph_it->second)))) {
            return false;
        }
    }
    return true;
}

static std::string ov_profiling_csv_field(const std::string & value) {
    std::string escaped = "\"";
    for (char c : value) {
        escaped += c;
        if (c == '"') {
            escaped += c;
        }
    }
    escaped += '"';
    return escaped;
}

static void dump_ov_profiling_info(const ov::InferRequest & infer_request) {
    if (ggml_openvino_getenv_int("GGML_OPENVINO_PROFILING") < 2) {
        return;
    }

    static std::atomic<uint64_t> inference_index{0};
    const uint64_t index = inference_index.fetch_add(1);
    const std::string path = "openvino_profile_" + std::to_string(index) + ".csv";
    std::ofstream output(path, std::ios::trunc);
    if (!output.is_open()) {
        GGML_LOG_WARN("ggml-openvino: failed to write profiling data to %s\n", path.c_str());
        return;
    }

    output << "status,real_time_us,cpu_time_us,start_time_us,node_type,node_name,exec_type\n";
    int64_t total_real_time = 0;
    int64_t total_cpu_time = 0;
    size_t executed_count = 0;
    for (const auto & info : infer_request.get_profiling_info()) {
        const char * status = "NOT_RUN";
        if (info.status == ov::ProfilingInfo::Status::EXECUTED) {
            status = "EXECUTED";
            total_real_time += info.real_time.count();
            total_cpu_time += info.cpu_time.count();
            executed_count++;
        } else if (info.status == ov::ProfilingInfo::Status::OPTIMIZED_OUT) {
            status = "OPTIMIZED_OUT";
        }

        output << status << ',' << info.real_time.count() << ',' << info.cpu_time.count() << ','
               << info.start_time.count() << ',' << ov_profiling_csv_field(info.node_type) << ','
               << ov_profiling_csv_field(info.node_name) << ',' << ov_profiling_csv_field(info.exec_type) << '\n';
    }

    GGML_LOG_INFO("ggml-openvino: profile %s: %zu executed nodes, %.3f ms device, %.3f ms CPU\n", path.c_str(),
                  executed_count, total_real_time / 1000.0, total_cpu_time / 1000.0);
}

static void reset_single_slot_recurrent_cache(ggml_cgraph * cgraph,
                                              const ModelParams & model_params,
                                              const ComputeParams & compute_params) {
    if (model_params.n_rs_slots != 1 || compute_params.cache_rs_reset_len == 0) {
        return;
    }
    GGML_ASSERT(compute_params.cache_rs_reset_idx == 0 && compute_params.cache_rs_reset_len == 1);

    std::set<ggml_backend_buffer_t> buffers;
    for (int i = 0; i < cgraph->n_nodes; i++) {
        auto * node = cgraph->nodes[i];
        if (node->op == GGML_OP_SCALE && GgmlOvDecoder::is_recurrent_cache(node->view_src) &&
            node->view_src->ne[1] == 1 && node->view_src->buffer != nullptr) {
            buffers.insert(node->view_src->buffer);
        }
    }
    for (auto * buffer : buffers) {
        ggml_backend_buffer_clear(buffer, 0);
    }
}

ov::Tensor create_ov_output_tensor(const std::shared_ptr<GgmlOvDecoder> & ggml_decoder,
                                   const std::shared_ptr<ov::InferRequest> & infer_request,
                                   int output_index,
                                   const ggml_tensor * ggml_tensor) {
    if (auto sliced = try_make_kv_sliced_tensor(ggml_decoder, std::string(ggml_tensor->name), ggml_tensor)) {
        return *sliced;
    }

    auto output_type = ggml_decoder->get_ov_type(ggml_tensor);
    ov::Shape output_shape;
    void * output_data = ggml_tensor->data;
    if (ggml_decoder->is_static()) {
        output_shape = infer_request->get_output_tensor(output_index).get_shape();
    } else {
        // For a CPY into a padded view_src (e.g. a padded KV cache buffer), the
        // OV ScatterUpdate node outputs the full view_src shape, not the CPY node's
        // own (smaller) shape.  Using the CPY shape here causes set_output_tensor to
        // fail with a shape-incompatibility error.  Use view_src's shape and data
        // pointer instead so the OV tensor matches the model output exactly.
        if (ggml_tensor->op == GGML_OP_CPY && ggml_tensor->view_src != nullptr &&
            ggml_nbytes(ggml_tensor) != ggml_nbytes(ggml_tensor->view_src)) {
            output_shape = GgmlOvDecoder::get_shape(ggml_tensor->view_src);
            output_data = ggml_tensor->view_src->data;
        } else {
            output_shape = GgmlOvDecoder::get_shape(ggml_tensor);
        }
    }

    // The sliced path above covers eligible KV outputs. This also covers recurrent state and full-size KV fallbacks.
    if (!ggml_openvino_getenv_int("GGML_OPENVINO_DISABLE_REMOTE_OUTPUTS") && !ggml_decoder->is_static() &&
        !ggml_decoder->is_splited_model() && ggml_openvino_buffer_is_remote(ggml_tensor) &&
        ggml_tensor->extra != nullptr) {
        auto * extra_base = static_cast<ggml_openvino_extra_base *>(ggml_tensor->extra);
        if (extra_base->type == ggml_openvino_extra_base::Type::TENSOR) {
            auto * tensor_extra = static_cast<ggml_openvino_tensor_extra *>(extra_base);
            if (tensor_extra->tensor != nullptr && tensor_extra->tensor->get_element_type() == output_type &&
                tensor_extra->tensor->get_shape() == output_shape) {
                return *tensor_extra->tensor;
            }
        }
    }

    ov::Tensor output_tensor(output_type, output_shape, output_data);
    return output_tensor;
}

// Rewrite ggml's KV rows into a relayout state that keeps the sequence on dim 2.
// ggml stores [seq][n_heads_kv * head_size]; the state wants [1, n_heads_kv, seq, head_size],
// a different element order, so the rows are copied instead of reinterpreted.
ov::Tensor kv_rows_to_seq_axis_2(const ov::Tensor & kv_tensor, size_t n_heads_kv) {
    const size_t rows = kv_tensor.get_shape()[2];
    const size_t head_size = kv_tensor.get_shape()[3] / n_heads_kv;
    const size_t elem = kv_tensor.get_element_type().size();
    const size_t head_bytes = head_size * elem;

    ov::Tensor out(kv_tensor.get_element_type(), ov::Shape{1, n_heads_kv, rows, head_size});
    const auto * src = static_cast<const uint8_t *>(kv_tensor.data());
    auto * dst = static_cast<uint8_t *>(out.data());
    for (size_t s = 0; s < rows; s++) {
        for (size_t h = 0; h < n_heads_kv; h++) {
            memcpy(dst + (h * rows + s) * head_bytes, src + (s * n_heads_kv + h) * head_bytes, head_bytes);
        }
    }
    return out;
}

template <typename T> void set_zero_diagonal(std::vector<T> & matrix, size_t rows, size_t cols, T zero_value = T{}) {
    for (size_t i = 0; i < rows; ++i) {
        size_t diag_col = std::min(i, cols - 1);
        matrix[i * cols + diag_col] = zero_value;
    }
}

ov::Tensor make_contiguous_split_input_tensor(const struct ggml_tensor * ggml_tensor, const ov::Shape & input_shape) {
    const size_t element_size = ggml_type_size(ggml_tensor->type);
    const size_t block_size = ggml_blck_size(ggml_tensor->type);

    GGML_ASSERT(block_size == 1 && "non-contiguous split inputs must be plain element types");

    const struct ggml_tensor * source_tensor = ggml_tensor->view_src != nullptr ? ggml_tensor->view_src : ggml_tensor;
    const size_t source_offset = ggml_tensor->view_src != nullptr ? ggml_tensor->view_offs : 0;

    std::vector<uint8_t> source_data(ggml_nbytes(source_tensor));
    ggml_backend_tensor_get(source_tensor, source_data.data(), 0, source_data.size());

    ov::Tensor input_tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), input_shape);
    auto * dst = static_cast<uint8_t *>(input_tensor.data());
    size_t dst_offset = 0;

    for (size_t i3 = 0; i3 < static_cast<size_t>(ggml_tensor->ne[3]); ++i3) {
        for (size_t i2 = 0; i2 < static_cast<size_t>(ggml_tensor->ne[2]); ++i2) {
            for (size_t i1 = 0; i1 < static_cast<size_t>(ggml_tensor->ne[1]); ++i1) {
                for (size_t i0 = 0; i0 < static_cast<size_t>(ggml_tensor->ne[0]); ++i0) {
                    const size_t src_offset = source_offset + i3 * ggml_tensor->nb[3] + i2 * ggml_tensor->nb[2] +
                                              i1 * ggml_tensor->nb[1] + i0 * ggml_tensor->nb[0];
                    std::memcpy(dst + dst_offset, source_data.data() + src_offset, element_size);
                    dst_offset += element_size;
                }
            }
        }
    }

    return input_tensor;
}

ov::Tensor convert_ggml_input_to_ov(const std::shared_ptr<GgmlOvDecoder> & ggml_decoder, const std::string & name) {
    const auto * ggml_tensor = ggml_decoder->get_input_ggml_tensor(name);

    if (auto sliced = try_make_kv_sliced_tensor(ggml_decoder, name, ggml_tensor)) {
        return *sliced;
    }

    // Static decode graphs trim the KV cache parameter to the graph's attention level (see
    // get_graph_input_shape): bind a level-shaped view over the same contiguous buffer so the
    // per-step state round trip is level-sized too. The buffer prefix is exactly what the
    // graph reads (attention rows [0, level)) and writes (cell ids < fill <= level).
    //
    // Either way the rows between the fill and the read span hold reused-heap garbage, and a
    // NaN bit pattern in there poisons the QK scores before the -INF mask can zero the column
    // (NaN + -INF = NaN) -- the observed acceptance flake. Zero [fill, span) on every decode
    // bind: the cost is a few hundred KB of memset and the rows are only ever read masked or
    // written first.
    if (ggml_decoder->is_static() && !ggml_decoder->is_prefill() &&
        ggml_decoder->get_compute_params().attention_size > 0) {
        const auto * kv_op = ggml_decoder->get_tensor_used_op(ggml_tensor);
        const bool flat_kv = ggml_tensor->ne[1] == 1 && ggml_tensor->ne[2] == 1 && ggml_tensor->ne[3] == 1;
        if (GgmlOvDecoder::is_kvcache(ggml_tensor, kv_op) && !flat_kv && ggml_is_contiguous(ggml_tensor)) {
            const int64_t span = std::min<int64_t>(ggml_decoder->get_compute_params().attention_size,
                                                   (int64_t) ggml_tensor->ne[1]);
            const auto * inp_pos_t = ggml_decoder->get_input_ggml_tensor("inp_pos");
            if (inp_pos_t != nullptr && inp_pos_t->ne[0] == 1 && inp_pos_t->data != nullptr &&
                !ggml_openvino_getenv_int("GGML_OPENVINO_NO_KV_ZEROIZE")) {
                const int64_t fill = *(const int32_t *) inp_pos_t->data;
                if (fill > 0 && fill < span) {
                    memset((char *) ggml_tensor->data + fill * ggml_tensor->nb[1], 0,
                           (size_t) (span - fill) * ggml_tensor->nb[1]);
                }
            }
            if (ggml_decoder->get_compute_params().attention_size < (int64_t) ggml_tensor->ne[1]) {
                ov::Shape level_shape = GgmlOvDecoder::get_shape(ggml_tensor);
                level_shape[2] = (size_t) ggml_decoder->get_compute_params().attention_size;
                return ov::Tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), level_shape, ggml_tensor->data);
            }
        }
    }

    if (ggml_tensor->extra != nullptr && !ggml_decoder->is_splited_model()) {
        auto * extra_base = static_cast<ggml_openvino_extra_base *>(ggml_tensor->extra);
        if (extra_base->type == ggml_openvino_extra_base::Type::TENSOR) {
            // GGML_LOG_DEBUG("Using ggml_tensor->extra as ov::Tensor for input: %s\n", name.c_str());
            auto * tensor_extra = static_cast<ggml_openvino_tensor_extra *>(extra_base);
            return *tensor_extra->tensor;
        }
    }

    // GGML_LOG_DEBUG("Converting ggml tensor to ov::Tensor for input: %s\n", name.c_str());
    auto * input_data = ggml_tensor->data;
    ov::Shape input_shape;
    if (ggml_tensor->op == GGML_OP_VIEW && !ggml_decoder->is_splited_model()) {
        // This case is added to make test-backend-ops work
        input_shape = GgmlOvDecoder::get_shape(ggml_tensor->view_src);
    } else {
        input_shape = GgmlOvDecoder::get_shape(ggml_tensor);
    }

    if (ggml_decoder->is_splited_model() && !ggml_is_contiguous(ggml_tensor)) {
        return make_contiguous_split_input_tensor(ggml_tensor, input_shape);
    }

    auto input_tensor = ov::Tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), input_shape, input_data);
    return input_tensor;
}

ov::Tensor get_ov_input_tensor(const std::shared_ptr<GgmlOvDecoder> & ggml_decoder, const std::string & param_name) {
    ov::Tensor input_tensor;
    auto extra_input = ggml_decoder->get_model_extra_inputs().find(param_name);
    if (extra_input != ggml_decoder->get_model_extra_inputs().end()) {
        input_tensor = ov::Tensor(extra_input->second.type, extra_input->second.shape);
        *input_tensor.data<int64_t>() = extra_input->second.value;
    } else {
        input_tensor = convert_ggml_input_to_ov(ggml_decoder, param_name);
    }
    return input_tensor;
}

ov::Tensor get_ov_input_tensor_static_decode(const std::shared_ptr<GgmlOvDecoder> & ggml_decoder,
                                             const std::string & param_name) {
    // NPU decoding stage
    if (ggml_decoder->get_model_extra_inputs().count(param_name)) {
        return get_ov_input_tensor(ggml_decoder, param_name);
    }
    const auto * ggml_tensor = ggml_decoder->get_input_ggml_tensor(param_name);
    const auto * op = ggml_decoder->get_tensor_used_op(ggml_tensor);

    if (GgmlOvDecoder::is_inp_tok(ggml_tensor, op) || GgmlOvDecoder::is_inp_pos(ggml_tensor, op) ||
        GgmlOvDecoder::is_kv_idx(ggml_tensor, op)) {
        // IMROPE's inp_pos holds one value per t/h/w/e plane instead of a single position;
        // with a single decode token the planes are still contiguous, so a flat copy works.
        const int n_planes = GgmlOvDecoder::is_inp_pos(ggml_tensor, op) ? GgmlOvDecoder::get_inp_pos_n_planes(op) : 1;
        assert(ggml_tensor->ne[0] == n_planes);
        ov::Shape input_shape = {1, 1, 1, (size_t) n_planes};
        ov::Tensor input_tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), input_shape);
        std::memcpy(input_tensor.data(), ggml_tensor->data, n_planes * ggml_type_size(ggml_tensor->type));
        return input_tensor;
    }

    if (GgmlOvDecoder::is_output_idx(ggml_tensor, op)) {
        ov::Shape input_shape = {1, 1, 1, 1};
        ov::Tensor input_tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), input_shape);
        int32_t inp_out_id = *((int32_t *) ggml_tensor->data);
        assert(ggml_tensor->ne[0] == 1);
        assert(inp_out_id == 0);
        *input_tensor.data<int32_t>() = inp_out_id;
        return input_tensor;
    }

    if (GgmlOvDecoder::is_inp_mask(ggml_tensor, op)) {
        // Clip graphs (mmproj) name their masks "attn_mask[_N]": a plain 2-D [n_kv, n_q]
        // streaming-window mask (the lfm3a audio encoder attends over [cached window |
        // this chunk], n_kv = window-1 + n_q). Bind it as-is -- {1, 1, 1, n_kv} per query
        // row is the LLM decode layout, meaningless here; the get_mask_ctx_size() width
        // re-sizing broke the score Add in the audio encoder.
        const std::string mask_name = ggml_tensor->name ? ggml_tensor->name : "";
        if (mask_name.rfind("attn_mask", 0) == 0 && ggml_tensor->ne[2] == 1 && ggml_tensor->ne[3] == 1) {
            ov::Tensor input_tensor(GgmlOvDecoder::get_ov_type(ggml_tensor),
                                    ov::Shape{1, 1, static_cast<size_t>(ggml_tensor->ne[1]),
                                              static_cast<size_t>(ggml_tensor->ne[0])});
            if (ggml_tensor->type == GGML_TYPE_F16 &&
                GgmlOvDecoder::get_ov_type(ggml_tensor) == ov::element::f32) {
                const auto * src = static_cast<const ggml_fp16_t *>(ggml_tensor->data);
                auto * dst = input_tensor.data<float>();
                for (size_t i = 0; i < input_tensor.get_size(); ++i) {
                    dst[i] = GGML_FP16_TO_FP32(src[i]);
                }
            } else {
                std::memcpy(input_tensor.data(), ggml_tensor->data, ggml_nbytes(ggml_tensor));
            }
            return input_tensor;
        }
        // Windowed layers read a shorter KV ring than the context, so the padded mask has to be
        // that wide -- and it must match the parameter shape from get_graph_input_shape().
        size_t context_size = ggml_decoder->get_mask_ctx_size(ggml_tensor);
        if (ggml_tensor->type == GGML_TYPE_F16) {
            std::vector<ggml_fp16_t> padded_data =
                pad_input<ggml_fp16_t>(ggml_tensor, 1, context_size, GGML_FP32_TO_FP16(-INFINITY));
            ov::Tensor input_tensor(ov::element::f16, ov::Shape{1, 1, 1, context_size});
            std::memcpy(input_tensor.data(), padded_data.data(), padded_data.size() * sizeof(ggml_fp16_t));
            return input_tensor;
        }

        std::vector<float> padded_data = pad_input<float>(ggml_tensor, 1, context_size, -INFINITY);
        ov::Tensor input_tensor(ov::element::f32, ov::Shape{1, 1, 1, context_size});
        auto * data_ptr = input_tensor.data<float>();
        std::copy(padded_data.begin(), padded_data.begin() + context_size, data_ptr);
        return input_tensor;
    }

    return get_ov_input_tensor(ggml_decoder, param_name);
}

ov::Tensor get_ov_input_tensor_static_prefill(const std::shared_ptr<GgmlOvDecoder> & ggml_decoder,
                                              const std::string & param_name,
                                              int chunk_index) {
    // NPU prompt processing stage
    const size_t input_len = ggml_decoder->get_input_len();
    const size_t chunk_size = ggml_decoder->m_prefill_chunk_size;
    const size_t chunk_valid_size = std::min(chunk_size, input_len - chunk_index * chunk_size);
    const size_t chunk_pad_size = chunk_size - chunk_valid_size;

    if (param_name == "chunk_valid_len") {
        ov::Tensor input_tensor(ov::element::i64, ov::Shape{1});
        *input_tensor.data<int64_t>() = (int64_t) chunk_valid_size;
        return input_tensor;
    }
    if (chunk_index > 0 && param_name == "cache_rs_reset_len") {
        // The recurrent-state clear belongs to the start of the sequence. Re-applying it on every
        // chunk would wipe the state accumulated by the preceding chunks, so disable it (a zero
        // length makes scale.cpp's keep-mask select every slot) after the first chunk.
        ov::Tensor input_tensor(ov::element::i64, ov::Shape{1});
        *input_tensor.data<int64_t>() = 0;
        return input_tensor;
    }
    if (ggml_decoder->get_model_extra_inputs().count(param_name)) {
        return get_ov_input_tensor(ggml_decoder, param_name);
    }
    const auto * ggml_tensor = ggml_decoder->get_input_ggml_tensor(param_name);
    const auto * op = ggml_decoder->get_tensor_used_op(ggml_tensor);

    if (GgmlOvDecoder::is_inp_pos(ggml_tensor, op) && GgmlOvDecoder::get_inp_pos_n_planes(op) > 1) {
        // IMROPE: inp_pos stacks n_planes (t/h/w/e) position planes, each of length
        // input_len; pad every plane independently so they stay aligned to chunk_size.
        const int n_planes = GgmlOvDecoder::get_inp_pos_n_planes(op);
        const size_t element_size = ggml_type_size(ggml_tensor->type);
        ov::Shape input_shape = {1, 1, 1, (size_t) n_planes * chunk_size};
        ov::Tensor input_tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), input_shape);
        for (int p = 0; p < n_planes; p++) {
            const char * src =
                (const char *) ggml_tensor->data + (p * input_len + chunk_index * chunk_size) * element_size;
            char * dst = (char *) input_tensor.data() + p * chunk_size * element_size;
            std::memcpy(dst, src, chunk_valid_size * element_size);
            if (chunk_pad_size > 0) {
                if (ggml_tensor->type == GGML_TYPE_I32) {
                    int32_t last_value = *((const int32_t *) src + chunk_valid_size - 1);
                    int32_t * out = (int32_t *) dst;
                    std::fill(out + chunk_valid_size, out + chunk_size, last_value + 1);
                } else if (ggml_tensor->type == GGML_TYPE_I64) {
                    int64_t last_value = *((const int64_t *) src + chunk_valid_size - 1);
                    int64_t * out = (int64_t *) dst;
                    std::fill(out + chunk_valid_size, out + chunk_size, last_value + 1);
                } else {
                    throw std::runtime_error("Unexpected tensor type for " + param_name);
                }
            }
        }
        return input_tensor;
    }

    if (GgmlOvDecoder::is_inp_tok(ggml_tensor, op) || GgmlOvDecoder::is_inp_pos(ggml_tensor, op) ||
        GgmlOvDecoder::is_kv_idx(ggml_tensor, op)) {
        ov::Shape input_shape = {1, 1, 1, chunk_size};
        ov::Tensor input_tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), input_shape);
        // copy the chunk_index-th chunk from ggml_tensor
        size_t element_size = ggml_type_size(ggml_tensor->type);
        void * input_data = (char *) ggml_tensor->data + chunk_index * chunk_size * element_size;
        std::memcpy(input_tensor.data(), input_data, chunk_valid_size * element_size);
        // pad the rest with last_value + 1, so that kv's of padded positions are inserted
        // to the next row after the valids row in the kvcache
        if (chunk_pad_size > 0) {
            if (ggml_tensor->type == GGML_TYPE_I32) {
                int32_t last_value =
                    *((int32_t *) ggml_tensor->data + (chunk_index * chunk_size + chunk_valid_size - 1));
                int32_t * output_data = input_tensor.data<int32_t>();
                std::fill(output_data + chunk_valid_size, output_data + chunk_size, last_value + 1);
            } else if (ggml_tensor->type == GGML_TYPE_I64) {
                int64_t last_value =
                    *((int64_t *) ggml_tensor->data + (chunk_index * chunk_size + chunk_valid_size - 1));
                int64_t * output_data = input_tensor.data<int64_t>();
                std::fill(output_data + chunk_valid_size, output_data + chunk_size, last_value + 1);
            } else {
                throw std::runtime_error("Unexpected tensor type for " + param_name);
            }
        }
        return input_tensor;
    }

    if (GgmlOvDecoder::is_output_idx(ggml_tensor, op)) {
        size_t output_len = ggml_decoder->get_compute_params().output_len;
        ov::Shape input_shape = {1, 1, 1, output_len};
        ov::Tensor input_tensor(GgmlOvDecoder::get_ov_type(ggml_tensor), input_shape);
        if (ggml_tensor->ne[0] == 0) {
            *input_tensor.data<int32_t>() = 0;
        } else {
            auto * data_addr = input_tensor.data<int32_t>();
            for (size_t i = 0; i < output_len; i++) {
                data_addr[i] = ((int32_t *) ggml_tensor->data)[i] % chunk_size;
            }
        }
        return input_tensor;
    }

    if (GgmlOvDecoder::is_inp_scale_rows(ggml_tensor, op)) {
        ov::Tensor input_tensor(ov::element::f32, ov::Shape{1, 1, chunk_size, 1});
        auto * dst = input_tensor.data<float>();
        const auto * src = static_cast<const float *>(ggml_tensor->data) + chunk_index * chunk_size;
        std::copy(src, src + chunk_valid_size, dst);
        std::fill(dst + chunk_valid_size, dst + chunk_size, 1.0f);
        return input_tensor;
    }

    if (GgmlOvDecoder::is_inp_mean(ggml_tensor, op)) {
        const size_t n_seqs = ggml_tensor->ne[1];
        const size_t src_stride = ggml_tensor->ne[0];
        const size_t copy_len = std::min<size_t>(chunk_valid_size, src_stride - chunk_index * chunk_size);
        ov::Tensor input_tensor(ov::element::f32, ov::Shape{1, 1, n_seqs, chunk_size});
        auto * dst = input_tensor.data<float>();
        std::fill(dst, dst + n_seqs * chunk_size, 0.0f);
        const auto * src = static_cast<const float *>(ggml_tensor->data) + chunk_index * chunk_size;
        for (size_t s = 0; s < n_seqs; s++) {
            std::memcpy(dst + s * chunk_size, src + s * src_stride, copy_len * sizeof(float));
        }
        return input_tensor;
    }

    if (GgmlOvDecoder::is_raw_embd(ggml_tensor, op)) {
        // Audio/image embeddings enter as a raw [n_embd, n_tokens] leaf (no token lookup), so
        // the chunk loop has no inp_tokens to pad on its behalf: bind the token axis padded to
        // the chunk with zero rows, mirroring how inp_tokens/inp_pos are padded above. Zero
        // rows keep every activation finite (an RMS norm of a zero vector is zero), their K/V
        // is scattered past the valid rows exactly like the padded positions' (last_value+1),
        // and every mask's padded key columns (-INF) keep those rows unread -- the same hygiene
        // the text path gets for its padded tail.
        const size_t n_embd = ggml_tensor->ne[0];
        ov::Tensor input_tensor(ov::element::f32, ov::Shape{1, 1, chunk_size, n_embd});
        auto * dst = input_tensor.data<float>();
        std::fill(dst, dst + chunk_size * n_embd, 0.0f);
        const size_t copy_len =
            std::min<size_t>(chunk_valid_size, ggml_tensor->ne[1] - chunk_index * chunk_size);
        const auto * src =
            static_cast<const float *>(ggml_tensor->data) + (size_t) chunk_index * chunk_size * n_embd;
        std::memcpy(dst, src, copy_len * n_embd * sizeof(float));
        return input_tensor;
    }

    if (GgmlOvDecoder::is_inp_mask(ggml_tensor, op)) {
        // Clip graphs (mmproj) name their masks "attn_mask[_N]": a plain 2-D [n_kv, n_q]
        // streaming-window mask (the lfm3a audio encoder attends over [cached window |
        // this chunk], n_kv = window-1 + n_q). Bind it as-is -- {1, 1, n_q, n_kv} --
        // because the LLM chunk layout below ({1,1,chunk_size,context_size} with widths
        // from get_mask_ctx_size()) re-sized the 69-wide mask to 38x38 and broke the
        // score Add in the audio encoder.
        const std::string mask_name = ggml_tensor->name ? ggml_tensor->name : "";
        if (mask_name.rfind("attn_mask", 0) == 0 && ggml_tensor->ne[2] == 1 && ggml_tensor->ne[3] == 1) {
            ov::Tensor input_tensor(GgmlOvDecoder::get_ov_type(ggml_tensor),
                                    ov::Shape{1, 1, static_cast<size_t>(ggml_tensor->ne[1]),
                                              static_cast<size_t>(ggml_tensor->ne[0])});
            if (ggml_tensor->type == GGML_TYPE_F16 &&
                GgmlOvDecoder::get_ov_type(ggml_tensor) == ov::element::f32) {
                const auto * src = static_cast<const ggml_fp16_t *>(ggml_tensor->data);
                auto * dst = input_tensor.data<float>();
                for (size_t i = 0; i < input_tensor.get_size(); ++i) {
                    dst[i] = GGML_FP16_TO_FP32(src[i]);
                }
            } else {
                std::memcpy(input_tensor.data(), ggml_tensor->data, ggml_nbytes(ggml_tensor));
            }
            return input_tensor;
        }
        size_t cols = ggml_tensor->ne[0];
        size_t rows = ggml_tensor->ne[1];
        size_t chunk_valid_rows = std::min(chunk_size, rows - chunk_index * chunk_size);
        // See get_mask_ctx_size(): the windowed module's mask is only as wide as its KV ring.
        size_t context_size = ggml_decoder->get_mask_ctx_size(ggml_tensor);
        if (ggml_openvino_getenv_int("GGML_OPENVINO_MASK_MODE") == 1) {
            // Diagnostic/fallback path: ignore the mask llama.cpp built and derive causality from
            // the token positions instead. What llama.cpp hands us is padded to its own notion of
            // the active KV span (n_kv rounded up to a multiple of 256), which does not line up
            // with the *whole* cache the static (NPU) graph reads: that mismatch is invisible for
            // the first row of a chunk -- the only row a 1-token prompt reads -- and corrupts
            // every later row. Rows past the chunk stay fully masked except for their own column,
            // exactly like set_zero_diagonal() does, so their softmax stays finite instead of
            // producing 0/0 = NaN that would leak into the recurrent state gather.
            const int64_t first_pos = (int64_t) chunk_index * chunk_size;
            const int64_t last_pos = first_pos + (int64_t) chunk_valid_rows - 1;
            std::vector<ggml_fp16_t> data((size_t) chunk_size * context_size, GGML_FP32_TO_FP16(-INFINITY));
            for (size_t r = 0; r < chunk_size; ++r) {
                const int64_t row_pos = first_pos + (int64_t) r;
                size_t upto = row_pos <= last_pos ? std::min<size_t>(context_size, (size_t) row_pos + 1) : 0;
                if (upto == 0) {
                    upto = std::min<size_t>(context_size, r + 1);  // keep padded rows finite
                }
                for (size_t c = 0; c < upto; ++c) {
                    data[r * context_size + c] = 0;
                }
            }
            ov::Tensor input_tensor(ov::element::f16, ov::Shape{1, 1, chunk_size, context_size});
            std::memcpy(input_tensor.data(), data.data(), data.size() * sizeof(ggml_fp16_t));
            return input_tensor;
        }
        if (ggml_tensor->type == GGML_TYPE_F16) {
            const auto * ggml_data =
                static_cast<const ggml_fp16_t *>(ggml_tensor->data) + chunk_index * chunk_size * cols;
            std::vector<ggml_fp16_t> padded_data = pad_input<ggml_fp16_t>(ggml_data, chunk_valid_rows, cols, chunk_size,
                                                                          context_size, GGML_FP32_TO_FP16(-INFINITY));
            set_zero_diagonal(padded_data, chunk_size, context_size, GGML_FP32_TO_FP16(0.0f));
            ov::Tensor input_tensor(ov::element::f16, ov::Shape{1, 1, chunk_size, context_size});
            std::memcpy(input_tensor.data(), padded_data.data(), padded_data.size() * sizeof(ggml_fp16_t));
            return input_tensor;
        }

        const auto * ggml_data = static_cast<const float *>(ggml_tensor->data) + chunk_index * chunk_size * cols;
        std::vector<float> padded_data =
            pad_input<float>(ggml_data, chunk_valid_rows, cols, chunk_size, context_size, -INFINITY);
        set_zero_diagonal(padded_data, chunk_size, context_size);
        ov::Tensor input_tensor(ov::element::f32, ov::Shape{1, 1, chunk_size, context_size});
        auto * data_ptr = input_tensor.data<float>();
        std::copy(padded_data.begin(), padded_data.begin() + chunk_size * context_size, data_ptr);
        return input_tensor;
    }

    return get_ov_input_tensor(ggml_decoder, param_name);
}

enum ggml_status naive_compute(ggml_cgraph * cgraph,
                               ov::Core & core,
                               const std::string & device,
                               const ov::AnyMap & config,
                               ov_compiled_model_cache & cache) {
    if (cgraph->n_nodes == 1 && (cgraph->nodes[0]->op == GGML_OP_NONE || cgraph->nodes[0]->op == GGML_OP_VIEW)) {
        return GGML_STATUS_SUCCESS;
    }

    std::unique_lock<std::mutex> compile_lock(cache.mutex);
    bool naive = true;
    auto model_weights = GgmlOvDecoder::create_weight_nodes(cgraph, naive);
    auto decoder = std::make_shared<GgmlOvDecoder>(cgraph, model_weights);
    auto input_model = std::make_shared<ov::frontend::ggml::InputModel>(decoder);
    auto model = ov::frontend::ggml::FrontEnd::convert(input_model, naive);
    if (ggml_openvino_getenv_int("GGML_OPENVINO_DUMP_IR")) {
        ov::serialize(model, "IR_naive.xml");
    }

    std::shared_ptr<ov::InferRequest> infer_request;
    auto remote_context = ggml_openvino_get_remote_context();
    ov::AnyMap compile_config = config;
    if (cgraph->nodes[0]->op == GGML_OP_MUL_MAT) {
        // TODO ACCURACY hint triggers a bug in GPU plugin/driver on Lunar Lake. Remove once CVS-182166 is resolved
        compile_config[ov::hint::execution_mode.name()] = ov::hint::ExecutionMode::PERFORMANCE;
    } else {
        compile_config[ov::hint::execution_mode.name()] = ov::hint::ExecutionMode::ACCURACY;
    }
    if (remote_context.has_value()) {
        infer_request = std::make_shared<ov::InferRequest>(
            core.compile_model(model, remote_context.value(), compile_config).create_infer_request());
    } else {
        infer_request = std::make_shared<ov::InferRequest>(
            core.compile_model(model, device, compile_config).create_infer_request());
    }
    std::vector<std::string> input_names;
    std::vector<std::string> output_names;
    for (const auto & param : model->get_parameters()) {
        input_names.push_back(param->get_friendly_name());
    }
    for (const auto & result : model->get_results()) {
        output_names.push_back(result->get_friendly_name());
    }
    // Destroy the frontend graph under the compilation lock as well: it can
    // still own edges into the shared weight nodes.
    model.reset();
    input_model.reset();
    decoder->clear_model_weights();
    model_weights.clear();
    compile_lock.unlock();

    for (size_t i = 0; i < input_names.size(); i++) {
        const auto & param_name = input_names[i];
        auto input_tensor = get_ov_input_tensor(decoder, param_name);
        infer_request->set_input_tensor(i, input_tensor);
    }

    // Use get_output_tensor + memcpy instead of set_output_tensor to avoid memory overwritten
    // when i/o buffer overlaps, e.g. the cgraph is a single PERMUTE

    infer_request->infer();

    for (size_t i = 0; i < output_names.size(); i++) {
        auto output_tensor = infer_request->get_output_tensor(i);
        const auto & model_outputs = decoder->get_model_outputs();
        auto model_output_it = model_outputs.find(output_names[i]);
        if (model_output_it == model_outputs.end()) {
            // Debug-only output added via GGML_OPENVINO_DEBUG_NODE; nothing to copy into.
            if (ggml_openvino_getenv_int("GGML_OPENVINO_DEBUG_OUTPUT") ||
                ggml_openvino_getenv_str("GGML_OPENVINO_DEBUG_NODE")) {
                print_output_tensor_info(output_names[i], output_tensor, output_tensor.data());
            }
            continue;
        }
        auto * ggml_tensor = model_output_it->second;
        std::memcpy(ggml_tensor->data, output_tensor.data(), output_tensor.get_byte_size());
    }
    return GGML_STATUS_SUCCESS;
}

enum ggml_status ov_graph_compute_dynamic(ggml_cgraph * cgraph, const std::shared_ptr<ov_runtime_context> & r_ctx) {
    auto & core = ov_singleton_core();
    const auto & config = ggml_openvino_get_compile_config();
    const auto & device = r_ctx->device;
    static auto is_static = false;

    static const bool cache_disabled = ggml_openvino_getenv_int("GGML_OPENVINO_DISABLE_CACHE");

    auto start_time = ggml_time_us();

    // is_model_splitted is O(n_nodes^2) plus a create_weight_nodes scan and takes ~20 ms
    // on a Llama-1B decode graph. It is called once per graph_compute invocation but the
    // graph shape is identical across all decode steps, so memoize by graph_key: compute
    // graph_key first (a few hundred us), and if the same key is already in decoder_cache
    // we know the graph is not splitted (only not-splitted graphs get inserted there).
    const int64_t cache_key_start_time = ggml_time_us();
    graph_key key(cgraph);
    const int64_t cache_key_compute_time = ggml_time_us() - cache_key_start_time;
    int64_t cache_lookup_time = 0;
    bool key_seen = false;
    if (!cache_disabled) {
        const int64_t cache_lookup_start_time = ggml_time_us();
        std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
        key_seen = r_ctx->decoder_cache.find(key) != r_ctx->decoder_cache.end();
        cache_lookup_time += ggml_time_us() - cache_lookup_start_time;
    }

    const int64_t model_split_check_start_time = ggml_time_us();
    bool model_is_splitted = key_seen ? false : is_model_splitted(cgraph);
    const int64_t model_split_check_time = ggml_time_us() - model_split_check_start_time;

    if (ggml_openvino_model_cache_only() && (model_is_splitted || is_naive(cgraph))) {
        GGML_LOG_ERROR("ggml-openvino: cache-only mode requires a complete model graph\n");
        return GGML_STATUS_FAILED;
    }
    if (is_naive(cgraph)) {
        if (!model_is_splitted) {
            return naive_compute(cgraph, core, device, config, *r_ctx->compiled_cache);
        }
    }

    std::shared_ptr<GgmlOvDecoder> ggml_decoder;
    std::shared_ptr<ov::InferRequest> infer_request;
    ModelParams m_params;
    ComputeParams c_params;
    const int64_t graph_param_compute_start_time = ggml_time_us();
    std::tie(m_params, c_params) = GgmlOvDecoder::compute_llm_params(cgraph, is_static);
    const int64_t graph_param_compute_time = ggml_time_us() - graph_param_compute_start_time;

    const bool cache_enabled = !model_is_splitted && !cache_disabled;
    const bool stateful_recurrent = r_ctx->stateful && m_params.state_size >= 0;
    const bool stateful_kv_only = r_ctx->stateful && !stateful_recurrent;
    if (r_ctx->stateful &&
        (m_params.n_seq > 1 || c_params.n_seq_active > 1 || m_params.n_rs_slots > 1 || m_params.has_rs_rollback)) {
        GGML_LOG_ERROR("OpenVINO stateful execution requires a single slot without recurrent rollback. Use -np 1.\n");
        return GGML_STATUS_FAILED;
    }
    if (stateful_recurrent && !cache_enabled) {
        GGML_LOG_ERROR("OpenVINO recurrent stateful execution requires an unsplit graph with model caching enabled.\n");
        return GGML_STATUS_FAILED;
    }
    bool cache_hit = false;

    int64_t decoder_end_time;
    int64_t conversion_end_time;
    int64_t compile_end_time;
    int64_t infer_end_time;
    int64_t ov_raw_infer_start;

    {
        std::shared_ptr<decoder_runtime_ctx> entry;
        ModelParams old_m_params;

        const int64_t cache_lookup_start_time = ggml_time_us();
        if (cache_enabled) {
            std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
            auto it = r_ctx->decoder_cache.find(key);
            cache_hit = it != r_ctx->decoder_cache.end();
            if (cache_hit) {
                entry = it->second;
            } else {
                r_ctx->clear_caches_locked();
                auto mutex = std::make_shared<std::mutex>();
                entry = std::make_shared<decoder_runtime_ctx>(mutex);
                r_ctx->decoder_cache[key] = entry;
            }
        } else {
            auto mutex = std::make_shared<std::mutex>();
            entry = std::make_shared<decoder_runtime_ctx>(mutex);
            cache_hit = false;
        }
        cache_lookup_time += ggml_time_us() - cache_lookup_start_time;

        std::lock_guard<std::mutex> lock(*(entry->mutex));
        cache_hit = cache_hit && entry->ptr && r_ctx->infer_request_cache.count(key) != 0;

        if (cache_hit) {
            ggml_decoder = entry->ptr;
            old_m_params = ggml_decoder->get_model_params();
            if (!ggml_decoder->is_splited_model()) {
                cache_hit = old_m_params.can_reuse_dynamically(m_params);
            }
        }

        std::vector<std::string> ov_input_names;
        std::vector<std::string> ov_output_names;

        if (cache_hit) {
            std::map<std::string, std::shared_ptr<ov::Node>> model_weights;
            ggml_decoder->set_compute_params(c_params);
            ggml_decoder->set_model_params(m_params);
            if (old_m_params.kv_buffer_changed(m_params) || !ggml_decoder->is_bound_to(cgraph)) {
                ggml_decoder->update_io(cgraph);
            }
            ggml_decoder->add_extra_inputs();
            {
                std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                infer_request = r_ctx->infer_request_cache.at(key);
                ov_input_names = r_ctx->ov_input_names_cache.at(key);
                ov_output_names = r_ctx->ov_output_names_cache.at(key);
            }

            if (stateful_kv_only) {
                const auto * inp_pos = get_inp_pos_tensor(cgraph);
                int32_t * pos_data = (int32_t *) inp_pos->data;
                auto pos_shape = GgmlOvDecoder::get_shape(inp_pos);
                if (pos_data[0] == 0) {
                    infer_request->reset_state();
                    r_ctx->stateful_kv_size = pos_shape[3];
                } else if (r_ctx->stateful_kv_size == static_cast<size_t>(pos_data[0])) {
                    r_ctx->stateful_kv_size += pos_shape[3];
                } else {
                    const size_t pos_begin = static_cast<size_t>(pos_data[0]);
                    const bool refill = pos_begin > r_ctx->stateful_kv_size;

                    // A refill seeds the state from ggml's KV cache, so it needs that cache to be a
                    // plain prefix: cell i must hold position i. An SWA layer keeps only the last
                    // n_swa positions, so once a position leaves the window ggml drops it and the
                    // remaining cells shift - cell i stops holding position i. While every position
                    // is still inside the window nothing has been dropped and the refill is sound.
                    if (refill && !ggml_decoder->get_model_params().swa_layers.empty()) {
                        const int n_swa = ggml_decoder->get_compute_params().swa_window;
                        if (n_swa < 0 || static_cast<size_t>(n_swa) < pos_begin) {
                            GGML_LOG_ERROR(
                                "GGML OpenVINO backend stateful inference failed: cannot resume at position %zu from a "
                                "state that holds %zu tokens, because the sliding-window layers keep only the last %d "
                                "positions. Run without GGML_OPENVINO_STATEFUL_EXECUTION.\n",
                                pos_begin, r_ctx->stateful_kv_size, n_swa);
                            return GGML_STATUS_FAILED;
                        }
                    }

                    const bool relayout_enabled = !ggml_openvino_getenv_int("GGML_OPENVINO_DISABLE_KV_STATE_RELAYOUT");

                    auto states = infer_request->query_state();
                    for (auto state : states) {
                        auto state_tensor = state.get_state();
                        auto state_tensor_shape = state_tensor.get_shape();

                        std::string state_name;
                        if (auto it = r_ctx->kv_state_input_name_map.find(state.get_name());
                            it != r_ctx->kv_state_input_name_map.end()) {
                            state_name = it->second;
                        }

                        // Which axis holds the sequence: pass::KVStateSeqAxis moves it from dim 1
                        // to dim 2. The head count is still needed below, because only a 1-head
                        // state stays byte-compatible with ggml's cache buffer. gemma-4 12B mixes
                        // 1-head full layers with 8-head sliding layers, so it is per state.
                        int n_heads_kv = ggml_decoder->get_model_params().n_heads_kv;
                        if (auto layer = extract_layer_from_name(state_name); layer.has_value()) {
                            n_heads_kv = ggml_decoder->get_n_heads_kv_for_layer(layer.value());
                        }
                        const bool relayout_this_state = relayout_enabled;
                        const size_t seq_axis = relayout_this_state ? 2 : 1;
                        const size_t head_axis = seq_axis == 2 ? 1 : 2;

                        if (refill) {
                            if (state_name.empty()) {
                                GGML_LOG_ERROR(
                                    "GGML OpenVINO backend stateful inference failed: no input found for the state\n");
                                return GGML_STATUS_FAILED;
                            }
                            auto kv_tensor = get_ov_input_tensor(ggml_decoder, state_name);
                            if (relayout_this_state && n_heads_kv != 1) {
                                // several heads with seq on dim 2: not the same bytes as ggml's
                                // buffer, so the rows have to be copied into the new order
                                state_tensor = kv_rows_to_seq_axis_2(kv_tensor, (size_t) n_heads_kv);
                            } else {
                                ov::Shape refill_shape(4);
                                refill_shape[0] = state_tensor_shape[0];
                                refill_shape[seq_axis] = kv_tensor.get_shape()[2];
                                refill_shape[head_axis] = state_tensor_shape[head_axis];
                                refill_shape[3] = state_tensor_shape[3];
                                kv_tensor.set_shape(refill_shape);
                                state_tensor = kv_tensor;
                            }
                            state_tensor_shape = state_tensor.get_shape();
                        }
                        // Only ever shrink to a prefix the source really has. Slicing past it used to
                        // surface as a bare ov::Exception from the ROI constructor.
                        if (state_tensor_shape[seq_axis] < pos_begin) {
                            GGML_LOG_ERROR(
                                "GGML OpenVINO backend stateful inference failed: state '%s' holds %zu tokens on axis "
                                "%zu, cannot resume at position %zu\n",
                                state.get_name().c_str(), state_tensor_shape[seq_axis], seq_axis, pos_begin);
                            return GGML_STATUS_FAILED;
                        }
                        ov::Coordinate begin = {0, 0, 0, 0};
                        ov::Coordinate end(state_tensor_shape.begin(), state_tensor_shape.end());
                        end[seq_axis] = pos_begin;
                        ov::Tensor new_state_tensor(state_tensor, begin, end);
                        state.set_state(new_state_tensor);
                    }
                    r_ctx->stateful_kv_size = pos_begin + pos_shape[3];
                }
            }

            decoder_end_time = ggml_time_us();
            conversion_end_time = decoder_end_time;
            compile_end_time = decoder_end_time;
        } else {
            // Compilation can mutate shared weight nodes, so serialize cold paths.
            // The lock is released before binding tensors or running inference.
            auto shared_cache = r_ctx->compiled_cache;
            std::unique_lock<std::mutex> compile_lock(shared_cache->mutex);
            auto weight_names = get_weight_names(cgraph);
            ggml_decoder = std::make_shared<GgmlOvDecoder>(cgraph, m_params, c_params, weight_names,
                                                          is_static, r_ctx->stateful, model_is_splitted);
            const std::string model_cache_dir = ggml_openvino_model_cache_dir();
            const std::string exact_key = cache_enabled ? compiled_graph_key(cgraph, *ggml_decoder, device) : "";
            uint64_t model_fp = 0;
            uint64_t exact_fp = 0;
            std::string blob_path, manifest_path;
            if (!model_cache_dir.empty() && !model_is_splitted) {
                const uint64_t extra_cfg =
                    ggml_openvino_model_cache_extra_cfg(r_ctx->stateful, stateful_recurrent);
                model_fp =
                    ggml_openvino_model_fingerprint(cgraph, device, /*fa=*/true, m_params.rope_params, 16, extra_cfg,
                                                    dynamic_graph_signature(cgraph, *ggml_decoder, m_params));
                exact_fp =
                    ggml_openvino_model_fingerprint(cgraph, device, /*fa=*/true, m_params.rope_params, 16, extra_cfg,
                                                    compiled_graph_key(cgraph, *ggml_decoder, device, 0, true));
                blob_path = ggml_openvino_model_cache_blob_path(model_cache_dir, model_fp);
                manifest_path = ggml_openvino_model_cache_manifest_path(model_cache_dir, model_fp);
            }
            std::string shared_key =
                cache_enabled ? (model_fp ? "dynamic:" + std::to_string(model_fp) : exact_key) : "";
            ov::CompiledModel shared_model;
            bool imported = false;
            auto shared_it = shared_cache->graphs.find(shared_key);
            if (!shared_key.empty() && shared_it != shared_cache->graphs.end() &&
                (model_fp == 0 || compiled_model_matches_graph(shared_it->second.decode, shared_it->second.input_names,
                                                               shared_it->second.output_names, *ggml_decoder))) {
                shared_model = shared_it->second.decode;
                infer_request = std::make_shared<ov::InferRequest>(shared_model.create_infer_request());
                ov_input_names = shared_it->second.input_names;
                ov_output_names = shared_it->second.output_names;
                imported = true;
                GGML_LOG_DEBUG("ggml-openvino: shared compiled model HIT (dynamic)\n");
            } else if (model_fp && shared_it != shared_cache->graphs.end()) {
                shared_key = exact_key;
                shared_it = shared_cache->graphs.find(shared_key);
                if (shared_it != shared_cache->graphs.end()) {
                    shared_model = shared_it->second.decode;
                    infer_request = std::make_shared<ov::InferRequest>(shared_model.create_infer_request());
                    ov_input_names = shared_it->second.input_names;
                    ov_output_names = shared_it->second.output_names;
                    imported = true;
                }
                model_fp = exact_fp;
                blob_path = ggml_openvino_model_cache_blob_path(model_cache_dir, model_fp);
                manifest_path = ggml_openvino_model_cache_manifest_path(model_cache_dir, model_fp);
            }
            if (cache_enabled) {
                std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                r_ctx->infer_request_cache.erase(key);
            }

            // Import standalone blobs with weights before graph conversion and compilation.
            // Split models use the plugin cache instead. The decoder still maps graph I/O.
            ov::AnyMap mc_config = config;
            if (!model_cache_dir.empty()) {
                mc_config.erase("CACHE_DIR");
                mc_config[ov::cache_mode.name()] = ov::CacheMode::OPTIMIZE_SPEED;
            }
            if (!imported && !model_cache_dir.empty() && !model_is_splitted) {
                const uint64_t preferred_fp = model_fp;
                bool dynamic_incompatible = preferred_fp == exact_fp;
                for (int candidate = 0; candidate < 2; ++candidate) {
                    if (imported || (candidate == 1 && preferred_fp == exact_fp)) {
                        break;
                    }
                    const uint64_t candidate_fp = candidate == 0 ? preferred_fp : exact_fp;
                    const std::string candidate_blob =
                        ggml_openvino_model_cache_blob_path(model_cache_dir, candidate_fp);
                    const std::string candidate_manifest =
                        ggml_openvino_model_cache_manifest_path(model_cache_dir, candidate_fp);
                    std::ifstream blob_in(candidate_blob, std::ios::binary);
                    std::vector<std::string> saved_inputs, saved_outputs;
                    if (!blob_in.is_open() ||
                        !ggml_openvino_model_cache_verify_manifest(candidate_manifest, cgraph, candidate_fp,
                                                                   saved_inputs, saved_outputs)) {
                        continue;
                    }
                    const int64_t import_start = ggml_time_us();
                    try {
                        ov::CompiledModel cm;
                        auto remote_context = ggml_openvino_get_remote_context();
                        if (remote_context.has_value()) {
                            cm = core.import_model(blob_in, remote_context.value(), mc_config);
                        } else {
                            cm = core.import_model(blob_in, device, mc_config);
                        }
                        // CPU serialization can rename Results that share a name with a Parameter.
                        if (!saved_inputs.empty() || !saved_outputs.empty()) {
                            ov_input_names = std::move(saved_inputs);
                            ov_output_names = std::move(saved_outputs);
                        } else {
                            for (const auto & p : cm.inputs()) {
                                ov_input_names.push_back(p.get_node()->get_friendly_name());
                            }
                            for (const auto & o : cm.outputs()) {
                                ov_output_names.push_back(o.get_node()->get_friendly_name());
                            }
                        }
                        if (!compiled_model_matches_graph(cm, ov_input_names, ov_output_names, *ggml_decoder)) {
                            dynamic_incompatible |= candidate == 0;
                            ov_input_names.clear();
                            ov_output_names.clear();
                            continue;
                        }
                        infer_request = std::make_shared<ov::InferRequest>(cm.create_infer_request());
                        shared_model = cm;
                        entry->ptr = ggml_decoder;
                        imported = true;
                        model_fp = candidate_fp;
                        blob_path = candidate_blob;
                        manifest_path = candidate_manifest;
                        if (candidate_fp == exact_fp) {
                            shared_key = exact_key;
                            shared_it = shared_cache->graphs.find(shared_key);
                        }
                        if (ggml_openvino_getenv_int("GGML_OPENVINO_PROFILING")) {
                            GGML_LOG_INFO("  - Model cache import time: %.3f ms \n",
                                          (ggml_time_us() - import_start) / 1000.0);
                        }
                        GGML_LOG_INFO("ggml-openvino: model cache HIT %s\n", candidate_blob.c_str());
                    } catch (const std::exception & e) {
                        GGML_LOG_WARN("ggml-openvino: model cache import failed: %s\n", e.what());
                        dynamic_incompatible |= candidate == 0;
                        imported = false;
                        ov_input_names.clear();
                        ov_output_names.clear();
                        infer_request.reset();
                        shared_model = {};
                    }
                }
                if (!imported && dynamic_incompatible) {
                    model_fp = exact_fp;
                    shared_key = exact_key;
                    shared_it = shared_cache->graphs.find(shared_key);
                    blob_path = ggml_openvino_model_cache_blob_path(model_cache_dir, model_fp);
                    manifest_path = ggml_openvino_model_cache_manifest_path(model_cache_dir, model_fp);
                }
            }

            std::shared_ptr<ov::Model> model;
            if (!imported && ggml_openvino_model_cache_only()) {
                GGML_LOG_ERROR(
                    "ggml-openvino: missing or incompatible compiled model: %s; run once without "
                    "GGML_OPENVINO_COMPILED_MODEL_CACHE_ONLY\n",
                    blob_path.c_str());
                return GGML_STATUS_FAILED;
            }
            if (!imported && ggml_openvino_weight_buffers_released()) {
                GGML_LOG_ERROR("ggml-openvino: cannot compile a new graph after releasing host weights\n");
                return GGML_STATUS_FAILED;
            }
            if (imported) {
                decoder_end_time = conversion_end_time = compile_end_time = ggml_time_us();
            } else {
                auto model_weights = GgmlOvDecoder::create_weight_nodes(cgraph);

                ggml_decoder = std::make_shared<GgmlOvDecoder>(cgraph, m_params, c_params, model_weights, is_static,
                                                               r_ctx->stateful, model_is_splitted);
                decoder_end_time = ggml_time_us();

                auto input_model = std::make_shared<ov::frontend::ggml::InputModel>(ggml_decoder);
                model = ov::frontend::ggml::FrontEnd::convert(input_model);
                ggml_decoder->clear_model_weights();
                conversion_end_time = ggml_time_us();

                if (ggml_openvino_getenv_int("GGML_OPENVINO_DUMP_IR")) {
                    char timestamped_filename[64];
                    auto timestamp = (long long) ggml_time_us();
                    snprintf(timestamped_filename, sizeof(timestamped_filename), "model_%lld.xml", timestamp);
                    ov::serialize(model, timestamped_filename);
                }

                // Use the cache-stripped config when the frontend model cache is active, so
                // the resulting CompiledModel can be exported and later re-imported.
                const ov::AnyMap & compile_config = model_cache_dir.empty() ? config : mc_config;
                ov::CompiledModel compiled_model;
                auto remote_context = ggml_openvino_get_remote_context();
                if (remote_context.has_value()) {
                    compiled_model = core.compile_model(model, remote_context.value(), compile_config);
                } else {
                    compiled_model = core.compile_model(model, device, compile_config);
                }
                compile_end_time = ggml_time_us();

                for (const auto & ov_param : model->get_parameters()) {
                    ov_input_names.push_back(ov_param->get_friendly_name());
                }
                for (const auto & ov_output : model->get_results()) {
                    ov_output_names.push_back(ov_output->get_friendly_name());
                }

                // Export to the frontend model cache for next time. Publish the blob first,
                // then the manifest, so a cache hit only sees fully written artifacts.
                if (!model_cache_dir.empty() && !model_is_splitted && model_fp != 0) {
                    try {
                        const std::string blob_tmp = ggml_openvino_model_cache_temp_path(blob_path);
                        const std::string manifest_tmp = ggml_openvino_model_cache_temp_path(manifest_path);
                        if (ggml_openvino_model_cache_write_manifest(manifest_tmp, cgraph, model_fp, ov_input_names,
                                                                     ov_output_names)) {
                            std::ofstream blob_out(blob_tmp, std::ios::binary | std::ios::trunc);
                            if (blob_out.is_open()) {
                                compiled_model.export_model(blob_out);
                                blob_out.close();
                                if (blob_out.good()) {
                                    if (std::rename(blob_tmp.c_str(), blob_path.c_str()) == 0 &&
                                        std::rename(manifest_tmp.c_str(), manifest_path.c_str()) == 0) {
                                        GGML_LOG_INFO("ggml-openvino: model cache WROTE %s\n", blob_path.c_str());
                                    } else {
                                        std::remove(blob_tmp.c_str());
                                        std::remove(manifest_tmp.c_str());
                                    }
                                } else {
                                    std::remove(blob_tmp.c_str());
                                    std::remove(manifest_tmp.c_str());
                                }
                            } else {
                                std::remove(manifest_tmp.c_str());
                            }
                        }
                    } catch (const std::exception & e) {
                        GGML_LOG_WARN("ggml-openvino: model cache export failed: %s\n", e.what());
                    }
                }

                infer_request = std::make_shared<ov::InferRequest>(compiled_model.create_infer_request());
                shared_model = compiled_model;
                entry->ptr = ggml_decoder;

            }  // end non-imported (compile) path

            entry->ptr = ggml_decoder;
            if (!shared_key.empty() && shared_it == shared_cache->graphs.end()) {
                shared_cache->graphs.emplace(shared_key,
                                             ov_compiled_graph{shared_model, {}, ov_input_names, ov_output_names});
            }
            if (cache_enabled) {
                std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                r_ctx->infer_request_cache[key] = infer_request;
                r_ctx->ov_input_names_cache[key] = ov_input_names;
                r_ctx->ov_output_names_cache[key] = ov_output_names;
            }

            if (stateful_kv_only && cache_enabled) {
                const auto * inp_pos = get_inp_pos_tensor(cgraph);
                auto pos_shape = GgmlOvDecoder::get_shape(inp_pos);
                // A freshly compiled model starts with an empty state, so it can only serve a
                // sequence from its beginning. A non-zero start position means the KV history was
                // built elsewhere (a restored ggml cache), which the state cannot adopt.
                const int32_t pos_begin = ((int32_t *) inp_pos->data)[0];
                if (pos_begin != 0) {
                    GGML_LOG_ERROR(
                        "GGML OpenVINO backend stateful inference failed: a new model was compiled for a sequence that "
                        "starts at position %d, but its state is empty. Run without "
                        "GGML_OPENVINO_STATEFUL_EXECUTION.\n",
                        pos_begin);
                    return GGML_STATUS_FAILED;
                }
                r_ctx->stateful_kv_size = pos_shape[3];
                const auto kv_param_res_names = ggml_decoder->get_kv_param_res_names();
                for (const auto & pair : kv_param_res_names) {
                    r_ctx->kv_state_input_name_map[pair.first + pair.second] = pair.first;
                }
            }
        }

        if (stateful_recurrent) {
            const auto * inp_pos = get_inp_pos_tensor(cgraph);
            const int32_t pos_begin = static_cast<const int32_t *>(inp_pos->data)[0];
            if (pos_begin == 0) {
                infer_request->reset_state();
            } else if (!cache_hit || old_m_params.kv_buffer_changed(m_params) || c_params.cache_rs_reset_len > 0 ||
                       pos_begin < 0 || static_cast<size_t>(pos_begin) != r_ctx->stateful_kv_size) {
                GGML_LOG_ERROR(
                    "OpenVINO recurrent stateful execution cannot restore or rewind a sequence. Restart at position 0 "
                    "or disable GGML_OPENVINO_STATEFUL_EXECUTION.\n");
                return GGML_STATUS_FAILED;
            }
        } else {
            reset_single_slot_recurrent_cache(cgraph, m_params, c_params);
        }

        for (size_t i = 0; i < ov_input_names.size(); i++) {
            const auto & param_name = ov_input_names[i];
            auto input_tensor = get_ov_input_tensor(ggml_decoder, param_name);
            infer_request->set_input_tensor(i, input_tensor);

            if (ggml_openvino_getenv_int("GGML_OPENVINO_DEBUG_INPUT")) {
                print_input_tensor_info(param_name, input_tensor);
            }
        }

        for (size_t i = 0; i < ov_output_names.size(); i++) {
            // Debug-only outputs added via GGML_OPENVINO_DEBUG_NODE (see
            // translate_session.cpp) have no corresponding ggml tensor; leave
            // them unbound so OpenVINO allocates its own tensor for them,
            // rather than aliasing a ggml buffer that may be overwritten by a
            // later in-place op before we get to read it.
            const auto & model_outputs = ggml_decoder->get_model_outputs();
            auto model_output_it = model_outputs.find(ov_output_names[i]);
            if (model_output_it == model_outputs.end()) {
                continue;
            }
            auto * ggml_tensor = model_output_it->second;
            if (ggml_nbytes(ggml_tensor) == 0) {
                continue;
            }
            auto output_tensor = create_ov_output_tensor(ggml_decoder, infer_request, i, ggml_tensor);
            infer_request->set_output_tensor(i, output_tensor);
        }

        ov_raw_infer_start = ggml_time_us();
        infer_request->infer();
        infer_end_time = ggml_time_us();
        if (stateful_recurrent) {
            const auto * inp_pos = get_inp_pos_tensor(cgraph);
            r_ctx->stateful_kv_size =
                static_cast<const int32_t *>(inp_pos->data)[0] + get_inp_pos_n_tokens(cgraph, inp_pos);
        }
        dump_ov_profiling_info(*infer_request);

        if (ggml_openvino_getenv_int("GGML_OPENVINO_DEBUG_OUTPUT") ||
            ggml_openvino_getenv_str("GGML_OPENVINO_DEBUG_NODE")) {
            for (size_t i = 0; i < ov_output_names.size(); i++) {
                const auto output_tensor = infer_request->get_output_tensor(i);
                print_output_tensor_info(ov_output_names[i], output_tensor, output_tensor.data());
            }
        }
        dump_ov_outputs_raw(infer_request, ov_output_names, "dyn");

        if (ggml_openvino_getenv_int("GGML_OPENVINO_PROFILING")) {
            GGML_LOG_INFO("\nGGML OpenVINO Backend: \n");
            GGML_LOG_INFO("  - Graph decoder time: %.3f ms \n", (decoder_end_time - start_time) / 1000.0);
            GGML_LOG_INFO("    - cache key compute time: %.3f ms \n", cache_key_compute_time / 1000.0);
            GGML_LOG_INFO("    - model split check time: %.3f ms \n", model_split_check_time / 1000.0);
            GGML_LOG_INFO("    - graph param compute time: %.3f ms \n", graph_param_compute_time / 1000.0);
            GGML_LOG_INFO("    - cache lookup time: %.3f ms \n", cache_lookup_time / 1000.0);
            if (!cache_hit) {
                GGML_LOG_INFO("  - Graph conversion time: %.3f ms \n",
                              (conversion_end_time - decoder_end_time) / 1000.0);
                GGML_LOG_INFO("  - Graph compile time: %.3f ms \n", (compile_end_time - conversion_end_time) / 1000.0);
            }
            GGML_LOG_INFO("  - Graph inference time: %.3f ms \n", (infer_end_time - compile_end_time) / 1000.0);
            GGML_LOG_INFO("    - OV raw infer time: %.3f ms \n", (infer_end_time - ov_raw_infer_start) / 1000.0);
        }
    }

    // GGML_OPENVINO_RELEASE_WEIGHTS (or GGML_OPENVINO_MEMORY_OPTIMIZE on GPU): the plugin holds its own device copy of
    // every weight after compile, so the host weight buffers can be dropped to reclaim
    // RSS. Release only while holding the compilation mutex so another context cannot
    // be reading host weights during conversion/compilation. Pin the shared compiled
    // models across backend teardown; a later context can create its own request without
    // reading the dropped pages. A new, uncached graph still fails fast above.
    if (cache_hit && ggml_openvino_release_weights_enabled()) {
        std::lock_guard<std::mutex> compile_lock(r_ctx->compiled_cache->mutex);
        if (!ggml_openvino_weight_buffers_released()) {
            ggml_openvino_release_weight_buffers();
        }
    }

    return GGML_STATUS_SUCCESS;
}

ov::AnyMap without_npuw(const ov::AnyMap & config) {
    ov::AnyMap out;
    for (const auto & kv : config) {
        // CACHE_MODE was added alongside NPUW_CACHE_DIR for the NPUW route; the plugin's
        // non-NPUW fallback route rejects it outright ("Option 'CACHE_MODE' is not
        // supported", which is how every clip-graph compile on the NPU died).
        if (kv.first.rfind("NPUW", 0) == 0 || kv.first == "NPU_USE_NPUW" || kv.first == "CACHE_MODE") {
            continue;
        }
        out.insert(kv);
    }
    return out;
}

enum ggml_status ov_graph_compute_static(ggml_cgraph * cgraph, const std::shared_ptr<ov_runtime_context> & r_ctx) {
    auto & core = ov_singleton_core();

    auto get_prefill_chunk_size = [] {
        static const int chunk_size = []() {
            int env_prefill_chunk_size = ggml_openvino_getenv_int("GGML_OPENVINO_PREFILL_CHUNK_SIZE");
            return env_prefill_chunk_size > 0 ? env_prefill_chunk_size : 256;
        }();
        return chunk_size;
    };

    // Normally NPU, but honors GGML_OPENVINO_DEVICE so GGML_OPENVINO_FORCE_STATIC can run the
    // static-shape path on CPU/GPU to isolate translation bugs from NPUW/NPU-driver issues.
    static std::string device = ggml_openvino_get_device_name();
    static auto is_static = true;
    static auto stateful = false;

    auto prefill_chunk_size = get_prefill_chunk_size();
    const auto & config = ggml_openvino_get_compile_config();
    // Compiled-model cache directory (blob + manifest with weights) for the level graphs below.
    // The static path is single-sequence: stateful/recurrent are both false here.
    const std::string model_cache_dir = ggml_openvino_model_cache_dir();
    const uint64_t cache_extra_base = ggml_openvino_model_cache_extra_cfg(false, false);
    // Split-model fragments never take the compiled-model cache (same rule as the old static path).
    const bool model_is_splitted = is_model_splitted(cgraph);

    if (is_naive(cgraph)) {
        return naive_compute(cgraph, core, device, config, *r_ctx->compiled_cache);
    }

    auto start_time = ggml_time_us();

    std::shared_ptr<GgmlOvDecoder> ggml_decoder;
    std::shared_ptr<ov::InferRequest> infer_request;
    ModelParams m_params;
    ComputeParams c_params;
    const auto * inp_pos_early = get_inp_pos_tensor(cgraph);
    const bool is_prefill_early = get_is_prefill(cgraph, inp_pos_early);
    std::tie(m_params, c_params) = GgmlOvDecoder::compute_llm_params(cgraph, is_static, is_prefill_early);

    const auto * inp_pos = inp_pos_early;
    const bool no_kv_cache = m_params.is_cacheless_attn;
    const auto is_prefill = no_kv_cache ? true : get_is_prefill(cgraph, inp_pos);
    const ov::AnyMap compile_config = no_kv_cache ? without_npuw(config) : config;
    if (m_params.n_heads_kv == -1) {
        prefill_chunk_size = inp_pos->ne[0];
    }
    graph_key key(cgraph);
    static const bool cache_enabled = !ggml_openvino_getenv_int("GGML_OPENVINO_DISABLE_CACHE");
    bool cache_hit = false;

    int64_t decoder_end_time;
    int64_t conversion_end_time;
    int64_t compile_end_time;
    int64_t infer_end_time;
    int64_t ov_raw_infer_start;
    int64_t ov_raw_infer_total = 0;

    std::shared_ptr<decoder_runtime_ctx> entry;
    ModelParams old_m_params;

    if (cache_enabled) {
        std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
        auto it = r_ctx->decoder_cache.find(key);
        cache_hit = it != r_ctx->decoder_cache.end();
        if (cache_hit) {
            entry = it->second;
        } else {
            r_ctx->clear_caches_locked();
            auto mutex = std::make_shared<std::mutex>();
            entry = std::make_shared<decoder_runtime_ctx>(mutex);
            r_ctx->decoder_cache[key] = entry;
        }
    } else {
        auto mutex = std::make_shared<std::mutex>();
        entry = std::make_shared<decoder_runtime_ctx>(mutex);
        cache_hit = false;
    }

    std::unique_lock<std::mutex> lock(*(entry->mutex));

    // Static decode runs against one graph per discrete attention level (NPU graphs cannot trim
    // their span at runtime, and baking the whole context makes every step attend the full span
    // however few cells are filled). Prefill and the dynamic path keep the single prefill/decode
    // pair.
    int decode_level = 0;
    if (is_static && !no_kv_cache && !is_prefill && c_params.attention_size_raw > 0 &&
        !ggml_openvino_getenv_int("GGML_OPENVINO_DISABLE_DECODE_LEVELS") && !g_decode_levels_disabled.load()) {
        decode_level = decode_attention_level(c_params.attention_size_raw, m_params.ctx_per_seq);
        c_params.attention_size = decode_level;
    }

    bool reuse_ok = true;
    if (decode_level > 0) {
        cache_hit = cache_hit && entry->ptr_decode_levels.count(decode_level) != 0 &&
                    r_ctx->infer_request_cache_decode_levels.count(key) != 0 &&
                    r_ctx->infer_request_cache_decode_levels.at(key).count(decode_level) != 0;
        if (cache_hit) {
            ggml_decoder = entry->ptr_decode_levels.at(decode_level);
            old_m_params = ggml_decoder->get_model_params();
            reuse_ok = old_m_params.can_reuse_statically(m_params);
            cache_hit = reuse_ok;
        }
    } else {
        cache_hit = cache_hit && entry->ptr && r_ctx->infer_request_cache.count(key) != 0 &&
                    r_ctx->infer_request_cache_prefill.count(key) != 0;
        if (cache_hit) {
            ggml_decoder = entry->ptr;
            old_m_params = ggml_decoder->get_model_params();
            reuse_ok = old_m_params.can_reuse_statically(m_params);
            cache_hit = reuse_ok;
        }
    }

    std::vector<std::string> ov_input_names_local;
    std::vector<std::string> ov_output_names_local;

    if (cache_hit) {
        std::map<std::string, std::shared_ptr<ov::Node>> model_weights;
        // Each phase binds against its own decoder: the two phases register different parameter
        // names once the SWA write-index rename applies to prefill only (see the comment on
        // ptr_prefill in utils.h). Do NOT mutate m_is_prefill here -- update_io() re-registers
        // the maps under whatever mode the object carries, and a mutated mode would rebuild the
        // prefill decoder's inputs under the decode naming (or vice versa) behind the binding's
        // back.
        ggml_decoder = decode_level > 0 ? entry->ptr_decode_levels.at(decode_level) :
                                          (is_prefill && entry->ptr_prefill) ? entry->ptr_prefill : entry->ptr;
        ggml_decoder->set_model_params(m_params);
        ggml_decoder->set_compute_params(c_params);
        if (old_m_params.kv_buffer_changed(m_params) || !ggml_decoder->is_bound_to(cgraph)) {
            ggml_decoder->update_io(cgraph);
        }
        ggml_decoder->add_extra_inputs();
        {
            std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
            if (decode_level > 0) {
                infer_request = r_ctx->infer_request_cache_decode_levels.at(key).at(decode_level);
            } else {
                infer_request =
                    is_prefill ? r_ctx->infer_request_cache_prefill.at(key) : r_ctx->infer_request_cache.at(key);
            }
            auto & input_names_map =
                is_prefill ? r_ctx->ov_input_names_cache_prefill : r_ctx->ov_input_names_cache;
            auto & output_names_map =
                is_prefill ? r_ctx->ov_output_names_cache_prefill : r_ctx->ov_output_names_cache;
            if (input_names_map.count(key) == 0 || output_names_map.count(key) == 0) {
                GGML_LOG_ERROR("ggml-openvino: no bound parameter-name list for key (is_prefill=%d, input=%d, "
                               "output=%d) - the other phase's compile never published one\n",
                               (int) is_prefill, (int) input_names_map.count(key),
                               (int) output_names_map.count(key));
                throw std::out_of_range("ggml-openvino: parameter-name list missing for the requested phase");
            }
            ov_input_names_local = input_names_map.at(key);
            ov_output_names_local = output_names_map.at(key);
        }

        decoder_end_time = ggml_time_us();
        conversion_end_time = decoder_end_time;
        compile_end_time = decoder_end_time;
    } else {
        // Only a failed compatibility check invalidates what is already compiled: a missing
        // decode level compiles alongside the still-valid pair, and a prefill-only compile
        // leaves existing decode levels alone.
        if (cache_enabled && !reuse_ok) {
            std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
            r_ctx->infer_request_cache.erase(key);
            r_ctx->infer_request_cache_prefill.erase(key);
            r_ctx->infer_request_cache_decode_levels.erase(key);
            entry->ptr_decode_levels.clear();
        }

        // What needs compiling: prefill passes compile the prefill graph (plus the legacy
        // context-baked decode graph on a fresh entry); decode passes compile only the missing
        // attention level. A failed can_reuse_statically erases the request caches above, so
        // request presence is the source of truth for what to rebuild. Each level's span is a
        // compile-time constant -- the NPU plugin rejects the dynamic intermediate shapes a
        // runtime-parameterized bound would produce (see compute_llm_params), so discrete
        // fully-static graphs are the only trim.
        const bool prefill_request_ok = reuse_ok && r_ctx->infer_request_cache_prefill.count(key) != 0;
        const bool decode_pair_request_ok = reuse_ok && r_ctx->infer_request_cache.count(key) != 0;
        const bool compile_prefill = is_prefill && !prefill_request_ok;
        const bool compile_decode =
                is_prefill ? (!decode_pair_request_ok && entry->ptr_decode_levels.empty()) : true;

        // The prefill graph always bakes the whole context span; only the decode graphs take the
        // discrete level (c_params carries it on decode passes, see the hit-determination above).
        ComputeParams c_params_ctx = c_params;
        if (decode_level > 0) {
            c_params_ctx.attention_size = m_params.ctx_per_seq;
        }

        auto shared_cache = r_ctx->compiled_cache;
        std::unique_lock<std::mutex> compile_lock(shared_cache->mutex);
        auto weight_names = get_weight_names(cgraph);

        // Compiled-model-cache compile config: OPTIMIZE_SPEED makes the exported blob embed the
        // weights (self-contained import -- weightless NPUW blobs would additionally demand a
        // WEIGHTS_PATH/MODEL_PTR contract), and the plugin blob cache is dropped for these graphs
        // because the model cache supersedes it.
        const ov::AnyMap cm_compile_config = [&compile_config] {
            ov::AnyMap cfg = compile_config;
            cfg.erase("CACHE_DIR");
            cfg.erase("NPUW_CACHE_DIR");
            cfg.erase(ov::cache_mode.name());
            cfg.insert(ov::cache_mode(ov::CacheMode::OPTIMIZE_SPEED));
            return cfg;
        }();

        const auto build_static_model = [&core, &compile_config, &cm_compile_config, &model_cache_dir, &cgraph,
                                         dump_ir_enabled = ggml_openvino_getenv_int(
                                             "GGML_OPENVINO_DUMP_IR")](
                                            const std::shared_ptr<GgmlOvDecoder> & decoder, const char * tag,
                                            std::shared_ptr<ov::Model> & model,
                                            ov::CompiledModel & compiled_model,
                                            std::shared_ptr<ov::InferRequest> & infer_request,
                                            int64_t & local_conversion_end_time,
                                            int64_t & local_compile_end_time,
                                            uint64_t cache_fp = 0,
                                            std::vector<std::string> * cached_in_names = nullptr,
                                            std::vector<std::string> * cached_out_names = nullptr) {
            // Compiled-model cache (blob + manifest with weights): a hit skips both the frontend
            // translation (~2 s) and the plugin compile (~1 s) on every process start.
            if (cache_fp != 0 && !model_cache_dir.empty()) {
                const std::string blob_path = ggml_openvino_model_cache_blob_path(model_cache_dir, cache_fp);
                const std::string manifest_path = ggml_openvino_model_cache_manifest_path(model_cache_dir, cache_fp);
                std::ifstream blob_in(blob_path, std::ios::binary);
                std::vector<std::string> saved_inputs, saved_outputs;
                if (blob_in.is_open() &&
                    ggml_openvino_model_cache_verify_manifest(manifest_path, cgraph, cache_fp, saved_inputs,
                                                              saved_outputs)) {
                    try {
                        ov::CompiledModel cm = core.import_model(blob_in, device, cm_compile_config);
                        std::vector<std::string> in_names, out_names;
                        if (!saved_inputs.empty() || !saved_outputs.empty()) {
                            in_names = std::move(saved_inputs);
                            out_names = std::move(saved_outputs);
                        } else {
                            for (const auto & p : cm.inputs()) {
                                in_names.push_back(p.get_node()->get_friendly_name());
                            }
                            for (const auto & o : cm.outputs()) {
                                out_names.push_back(o.get_node()->get_friendly_name());
                            }
                        }
                        if (!compiled_model_matches_graph(cm, in_names, out_names, *decoder)) {
                            GGML_LOG_WARN("ggml-openvino: model cache IMPORT mismatch for %s; recompiling\n", tag);
                        } else {
                            compiled_model = std::move(cm);
                            infer_request = std::make_shared<ov::InferRequest>(compiled_model.create_infer_request());
                            if (cached_in_names != nullptr) {
                                *cached_in_names = std::move(in_names);
                            }
                            if (cached_out_names != nullptr) {
                                *cached_out_names = std::move(out_names);
                            }
                            local_conversion_end_time = local_compile_end_time = ggml_time_us();
                            GGML_LOG_INFO("ggml-openvino: model cache IMPORT %s\n", tag);
                            return;
                        }
                    } catch (const std::exception & e) {
                        GGML_LOG_WARN("ggml-openvino: model cache import failed for %s: %s\n", tag, e.what());
                    }
                }
            }
            auto input_model = std::make_shared<ov::frontend::ggml::InputModel>(decoder);
            model = ov::frontend::ggml::FrontEnd::convert(input_model);
            decoder->clear_model_weights();
            local_conversion_end_time = ggml_time_us();

            if (dump_ir_enabled) {
                const auto dump_ir_timestamp = static_cast<long long>(ggml_time_us());
                char timestamped_filename[64];
                snprintf(timestamped_filename, sizeof(timestamped_filename), "model_%s_%lld.xml", tag,
                         dump_ir_timestamp);
                ov::serialize(model, timestamped_filename);
            }

            compiled_model = core.compile_model(model, device, cache_fp != 0 ? cm_compile_config : compile_config);
            infer_request = std::make_shared<ov::InferRequest>(compiled_model.create_infer_request());
            local_compile_end_time = ggml_time_us();
            if (cache_fp != 0 && !model_cache_dir.empty()) {
                // Publish blob first, then manifest, so a cache hit only sees complete artifacts.
                try {
                    const std::string blob_path = ggml_openvino_model_cache_blob_path(model_cache_dir, cache_fp);
                    const std::string manifest_path =
                        ggml_openvino_model_cache_manifest_path(model_cache_dir, cache_fp);
                    const std::string blob_tmp = ggml_openvino_model_cache_temp_path(blob_path);
                    const std::string manifest_tmp = ggml_openvino_model_cache_temp_path(manifest_path);
                    std::vector<std::string> in_names, out_names;
                    for (const auto & p : model->get_parameters()) {
                        in_names.push_back(p->get_friendly_name());
                    }
                    for (const auto & r : model->get_results()) {
                        out_names.push_back(r->get_friendly_name());
                    }
                    if (ggml_openvino_model_cache_write_manifest(manifest_tmp, cgraph, cache_fp, in_names,
                                                                 out_names)) {
                        std::ofstream blob_out(blob_tmp, std::ios::binary | std::ios::trunc);
                        if (blob_out.is_open()) {
                            compiled_model.export_model(blob_out);
                            blob_out.close();
                            if (blob_out.good() && std::rename(blob_tmp.c_str(), blob_path.c_str()) == 0 &&
                                std::rename(manifest_tmp.c_str(), manifest_path.c_str()) == 0) {
                                GGML_LOG_INFO("ggml-openvino: model cache WROTE %s\n", tag);
                            } else {
                                std::remove(blob_tmp.c_str());
                                std::remove(manifest_tmp.c_str());
                            }
                        }
                    }
                } catch (const std::exception & e) {
                    GGML_LOG_WARN("ggml-openvino: model cache export failed for %s: %s\n", tag, e.what());
                }
            }
        };

        if (is_prefill && compile_prefill && compile_decode) {
        // One decoder per phase (see ptr_prefill in utils.h): the prefill graph registers the
        // renamed SWA write-index parameters, the decode graph the merged ones.
        auto local_decoder_prefill = std::make_shared<GgmlOvDecoder>(
            cgraph, m_params, c_params_ctx, weight_names, is_static, stateful, false, true, prefill_chunk_size);
        auto local_decoder_decode =
            no_kv_cache ? local_decoder_prefill :
                          std::make_shared<GgmlOvDecoder>(cgraph, m_params, c_params, weight_names, is_static,
                                                          stateful, false, false, prefill_chunk_size);
        auto & local_decoder = local_decoder_prefill;
        const std::string shared_key =
            cache_enabled ? compiled_graph_key(cgraph, *local_decoder, device, prefill_chunk_size) : "";
        auto shared_it = shared_cache->graphs.find(shared_key);
        if (!shared_key.empty() && shared_it != shared_cache->graphs.end()) {
            auto & compiled = shared_it->second;
            auto prefill_request = std::make_shared<ov::InferRequest>(compiled.prefill.create_infer_request());
            auto decode_request = no_kv_cache ?
                                      prefill_request :
                                      std::make_shared<ov::InferRequest>(compiled.decode.create_infer_request());
            ggml_decoder = local_decoder;
            entry->ptr_prefill = local_decoder_prefill;
            entry->ptr = local_decoder_decode;
            if (!no_kv_cache) {
                const int baked_decode_level =
                    decode_attention_level(c_params.attention_size, m_params.ctx_per_seq);
                entry->ptr_decode_levels[baked_decode_level] = local_decoder_decode;
                std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                r_ctx->infer_request_cache_decode_levels[key][baked_decode_level] = decode_request;
            }
            infer_request = prefill_request;
            // The prefill and decode models carry different parameter lists once the SWA
            // write-index rename applies to prefill only; bind against the matching one.
            ov_input_names_local = compiled.input_names_prefill;
            ov_output_names_local = compiled.output_names_prefill;
            r_ctx->infer_request_cache_prefill[key] = prefill_request;
            r_ctx->infer_request_cache[key] = decode_request;
            r_ctx->ov_input_names_cache[key] = compiled.input_names_decode;
            r_ctx->ov_output_names_cache[key] = compiled.output_names_decode;
            r_ctx->ov_input_names_cache_prefill[key] = ov_input_names_local;
            r_ctx->ov_output_names_cache_prefill[key] = ov_output_names_local;
            decoder_end_time = conversion_end_time = compile_end_time = ggml_time_us();
            GGML_LOG_DEBUG("ggml-openvino: shared compiled model HIT (static)\n");
        } else {
            std::shared_ptr<ov::Model> model;
            auto model_weights = GgmlOvDecoder::create_weight_nodes(cgraph);

            auto ggml_decoder_prefill = std::make_shared<GgmlOvDecoder>(
                cgraph, m_params, c_params_ctx, model_weights, is_static, stateful, false, true, prefill_chunk_size);
            auto ggml_decoder_decode =
                no_kv_cache ? ggml_decoder_prefill :
                              std::make_shared<GgmlOvDecoder>(cgraph, m_params, c_params, model_weights, is_static,
                                                              stateful, false, false, prefill_chunk_size);
            decoder_end_time = ggml_time_us();

            std::shared_ptr<ov::Model> model_prefill;
            std::shared_ptr<ov::Model> model_decode;
            ov::CompiledModel compiled_model_prefill;
            ov::CompiledModel compiled_model_decode;
            std::shared_ptr<ov::InferRequest> infer_request_prefill;
            std::shared_ptr<ov::InferRequest> infer_request_decode;
            int64_t prefill_conversion_end_time;
            int64_t decode_conversion_end_time;
            int64_t prefill_compile_end_time;
            int64_t decode_compile_end_time;
            // Per-phase compiled-model cache fingerprints: the phase tag and decode level are
            // mixed into extra_cfg so each level graph gets its own blob.
            uint64_t fp_prefill = 0;
            uint64_t fp_decode = 0;
            std::vector<std::string> cached_in_prefill;
            std::vector<std::string> cached_out_prefill;
            std::vector<std::string> cached_in_decode;
            std::vector<std::string> cached_out_decode;
            if (!model_cache_dir.empty() && !model_is_splitted) {
                fp_prefill = ggml_openvino_model_fingerprint(
                    cgraph, device, /*fa=*/true, m_params.rope_params, 16,
                    cache_extra_base ^ 0x9E3779B97F4A7C15ull /* "prefill" */,
                    dynamic_graph_signature(cgraph, *ggml_decoder_prefill, m_params));
                // Decode graphs stay on the compile path: importing a second model into the
                // shared weights bank trips weights_bank.cpp's duplicate-UID assert (NPUW's
                // import has no dedup -- the GenAI flow imports one model per process), and
                // per-model banks would multiply the device weight footprint (defect-7 budget).
                // The prefill conversion is the expensive one (2.3 s) -- it alone is cached.
            }
            build_static_model(ggml_decoder_prefill, "prefill", model_prefill, compiled_model_prefill,
                               infer_request_prefill, prefill_conversion_end_time, prefill_compile_end_time,
                               fp_prefill, &cached_in_prefill, &cached_out_prefill);
            if (no_kv_cache) {
                model_decode = model_prefill;
                compiled_model_decode = compiled_model_prefill;
                infer_request_decode = infer_request_prefill;
                decode_conversion_end_time = prefill_conversion_end_time;
                decode_compile_end_time = prefill_compile_end_time;
            } else {
                build_static_model(ggml_decoder_decode, "decode", model_decode, compiled_model_decode,
                                   infer_request_decode, decode_conversion_end_time, decode_compile_end_time,
                                   fp_decode, &cached_in_decode, &cached_out_decode);
            }
            conversion_end_time = std::max(prefill_conversion_end_time, decode_conversion_end_time);
            compile_end_time = std::max(prefill_compile_end_time, decode_compile_end_time);

            model = is_prefill ? model_prefill : model_decode;
            ggml_decoder = is_prefill ? ggml_decoder_prefill : ggml_decoder_decode;
            infer_request = is_prefill ? infer_request_prefill : infer_request_decode;
            // Store each phase's OWN decoder. Storing the current pass's decoder in ptr aliased
            // ptr with ptr_prefill whenever the first pass was a prefill; the next decode pass
            // then re-registered that one object with the merged (decode) parameter names via
            // update_io, and the following prefill pass bound against names its decoder no
            // longer had.
            entry->ptr_prefill = ggml_decoder_prefill;
            entry->ptr = ggml_decoder_decode;

            // Capture the two graphs' parameter/result lists separately: once the interleaved-SWA
            // write-index rename applies to the prefill graph only, the pair no longer shares one
            // parameter list, and binding a graph against the other's names fails.
            std::vector<std::string> ov_input_names_prefill_local;
            std::vector<std::string> ov_output_names_prefill_local;
            if (!cached_in_prefill.empty()) {
                // imported from the compiled-model cache: no frontend model, use the saved names
                ov_input_names_prefill_local = std::move(cached_in_prefill);
                ov_output_names_prefill_local = std::move(cached_out_prefill);
            } else {
                for (const auto & ov_param : model_prefill->get_parameters()) {
                    ov_input_names_prefill_local.push_back(ov_param->get_friendly_name());
                }
                for (const auto & ov_output : model_prefill->get_results()) {
                    ov_output_names_prefill_local.push_back(ov_output->get_friendly_name());
                }
            }
            std::vector<std::string> ov_input_names_decode_local;
            std::vector<std::string> ov_output_names_decode_local;
            if (!cached_in_decode.empty()) {
                ov_input_names_decode_local = std::move(cached_in_decode);
                ov_output_names_decode_local = std::move(cached_out_decode);
            } else {
                for (const auto & ov_param : model_decode->get_parameters()) {
                    ov_input_names_decode_local.push_back(ov_param->get_friendly_name());
                }
                for (const auto & ov_output : model_decode->get_results()) {
                    ov_output_names_decode_local.push_back(ov_output->get_friendly_name());
                }
            }
            if (no_kv_cache) {
                // One model serves both phases: keep the lists identical so either lookup works.
                ov_input_names_prefill_local = ov_input_names_decode_local;
                ov_output_names_prefill_local = ov_output_names_decode_local;
            }
            ov_input_names_local = is_prefill ? ov_input_names_prefill_local : ov_input_names_decode_local;
            ov_output_names_local = is_prefill ? ov_output_names_prefill_local : ov_output_names_decode_local;

            if (!shared_key.empty()) {
                shared_cache->graphs.emplace(
                    shared_key,
                    ov_compiled_graph{compiled_model_decode,
                                      compiled_model_prefill,
                                      {},
                                      {},
                                      ov_input_names_prefill_local,
                                      ov_output_names_prefill_local,
                                      ov_input_names_decode_local,
                                      ov_output_names_decode_local});
            }

            // The decode half's baked span becomes its discrete level: ctx on a prefill-first
            // pass, the current level on the rare decode-first dual compile.
            const int baked_decode_level =
                decode_attention_level(no_kv_cache ? m_params.ctx_per_seq : c_params.attention_size,
                                       m_params.ctx_per_seq);
            if (cache_enabled) {
                std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                r_ctx->infer_request_cache_prefill[key] = infer_request_prefill;
                r_ctx->infer_request_cache[key] = infer_request_decode;
                r_ctx->infer_request_cache_decode_levels[key][baked_decode_level] = infer_request_decode;
                r_ctx->ov_input_names_cache[key] = ov_input_names_decode_local;
                r_ctx->ov_output_names_cache[key] = ov_output_names_decode_local;
                r_ctx->ov_input_names_cache_prefill[key] = ov_input_names_prefill_local;
                r_ctx->ov_output_names_cache_prefill[key] = ov_output_names_prefill_local;
            }
            if (!no_kv_cache) {
                entry->ptr_decode_levels[baked_decode_level] = ggml_decoder_decode;
            }
        }
        } else if (compile_decode) {
            // Decode-only: the pair exists (or prefill is deferred to its first pass); compile
            // just this attention level. Private to this backend -- the shared pair cache holds
            // two-phase entries only.
            //
            // The NPU device budget fits prefill plus ONE decode graph: with a second decode
            // level resident, its first execute dies with ZE_RESULT_ERROR_UNINITIALIZED (the
            // defect-7 signature -- weights banks are per CompiledModel, and prefill+decode of
            // one pair already take the budget). Evict the other levels; a later switch back
            // reloads them from the disk blob cache.
            {
                std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                r_ctx->infer_request_cache_decode_levels.erase(key);
                entry->ptr_decode_levels.clear();
            }
            std::shared_ptr<ov::Model> model_level;
            auto model_weights = GgmlOvDecoder::create_weight_nodes(cgraph);
            auto decoder_level = std::make_shared<GgmlOvDecoder>(cgraph, m_params, c_params, model_weights,
                                                                 is_static, stateful, false, false,
                                                                 prefill_chunk_size);
            decoder_end_time = ggml_time_us();
            int64_t level_conversion_end_time;
            int64_t level_compile_end_time;
            ov::CompiledModel compiled_model_level;
            // Decode level graphs stay on the compile path (shared weights bank -- see the dual
            // branch comment); only their conversion would benefit and it is the cheap one.
            build_static_model(decoder_level, "decode", model_level, compiled_model_level, infer_request,
                               level_conversion_end_time, level_compile_end_time);
            conversion_end_time = level_conversion_end_time;
            compile_end_time = level_compile_end_time;
            ggml_decoder = decoder_level;

            std::vector<std::string> ov_input_names_level_local;
            std::vector<std::string> ov_output_names_level_local;
            for (const auto & ov_param : model_level->get_parameters()) {
                ov_input_names_level_local.push_back(ov_param->get_friendly_name());
            }
            for (const auto & ov_output : model_level->get_results()) {
                ov_output_names_level_local.push_back(ov_output->get_friendly_name());
            }
            ov_input_names_local = ov_input_names_level_local;
            ov_output_names_local = ov_output_names_level_local;

            if (cache_enabled) {
                std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                if (decode_level > 0) {
                    r_ctx->infer_request_cache_decode_levels[key][decode_level] = infer_request;
                    // All levels share one parameter list (constants differ only in value).
                    r_ctx->ov_input_names_cache[key] = ov_input_names_level_local;
                    r_ctx->ov_output_names_cache[key] = ov_output_names_level_local;
                } else {
                    // Levels were disabled at runtime (device-budget fallback): this graph is
                    // the full-ctx decode -- publish it as the ctx-pair decode, or every step
                    // would recompile.
                    r_ctx->infer_request_cache[key] = infer_request;
                    r_ctx->ov_input_names_cache[key] = ov_input_names_level_local;
                    r_ctx->ov_output_names_cache[key] = ov_output_names_level_local;
                }
            }
            if (decode_level > 0) {
                entry->ptr_decode_levels[decode_level] = decoder_level;
            } else {
                entry->ptr = decoder_level;
            }
            GGML_LOG_INFO("ggml-openvino: compiled decode graph for attention level %d\n", decode_level);
        } else {
            // Prefill-only: decode levels already exist from a decode-first pass.
            std::shared_ptr<ov::Model> model_prefill_only;
            auto model_weights = GgmlOvDecoder::create_weight_nodes(cgraph);
            auto decoder_prefill = std::make_shared<GgmlOvDecoder>(cgraph, m_params, c_params_ctx, model_weights,
                                                                   is_static, stateful, false, true,
                                                                   prefill_chunk_size);
            decoder_end_time = ggml_time_us();
            int64_t prefill_conversion_end_time;
            int64_t prefill_compile_end_time;
            ov::CompiledModel compiled_model_prefill;
            // This branch runs when decode level graphs already exist in the shared weights
            // bank -- a CM-cache import here would collide with them (see the dual branch
            // comment), so the prefill recompiles.
            build_static_model(decoder_prefill, "prefill", model_prefill_only, compiled_model_prefill,
                               infer_request, prefill_conversion_end_time, prefill_compile_end_time);
            conversion_end_time = prefill_conversion_end_time;
            compile_end_time = prefill_compile_end_time;
            ggml_decoder = decoder_prefill;

            std::vector<std::string> ov_input_names_prefill_local;
            std::vector<std::string> ov_output_names_prefill_local;
            for (const auto & ov_param : model_prefill_only->get_parameters()) {
                ov_input_names_prefill_local.push_back(ov_param->get_friendly_name());
            }
            for (const auto & ov_output : model_prefill_only->get_results()) {
                ov_output_names_prefill_local.push_back(ov_output->get_friendly_name());
            }
            ov_input_names_local = ov_input_names_prefill_local;
            ov_output_names_local = ov_output_names_prefill_local;

            if (cache_enabled) {
                std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                r_ctx->infer_request_cache_prefill[key] = infer_request;
                r_ctx->ov_input_names_cache_prefill[key] = ov_input_names_prefill_local;
                r_ctx->ov_output_names_cache_prefill[key] = ov_output_names_prefill_local;
            }
            entry->ptr_prefill = decoder_prefill;
        }
    }

    reset_single_slot_recurrent_cache(cgraph, m_params, c_params);

    if (is_prefill) {
        auto inp_len = get_inp_pos_n_tokens(cgraph, inp_pos);
        for (int chunk_index = 0; chunk_index * prefill_chunk_size < inp_len; chunk_index++) {
            for (size_t i = 0; i < ov_input_names_local.size(); i++) {
                const auto & param_name = ov_input_names_local[i];
                auto input_tensor = get_ov_input_tensor_static_prefill(ggml_decoder, param_name, chunk_index);
                infer_request->set_input_tensor(i, input_tensor);

                if (ggml_openvino_getenv_int("GGML_OPENVINO_DEBUG_INPUT")) {
                    const auto input_tensor = infer_request->get_input_tensor(i);
                    print_input_tensor_info(param_name, input_tensor);
                }
            }

            for (size_t i = 0; i < ov_output_names_local.size(); i++) {
                const auto & model_outputs = ggml_decoder->get_model_outputs();
                auto model_output_it = model_outputs.find(ov_output_names_local[i]);
                if (model_output_it == model_outputs.end()) {
                    continue;
                }
                auto * ggml_tensor = model_output_it->second;
                if (ggml_nbytes(ggml_tensor) == 0) {
                    // Zero-row in-place writeback (e.g. the empty s_copy defrag remainder). The OV
                    // Result is the full cache, so binding it over this 0-byte buffer overflows it.
                    continue;
                }
                auto output_tensor = create_ov_output_tensor(ggml_decoder, infer_request, i, ggml_tensor);
                infer_request->set_output_tensor(i, output_tensor);
            }

            ov_raw_infer_start = ggml_time_us();
            infer_request->infer();
            ov_raw_infer_total += ggml_time_us() - ov_raw_infer_start;

            if (ggml_openvino_getenv_int("GGML_OPENVINO_DEBUG_OUTPUT") ||
                ggml_openvino_getenv_str("GGML_OPENVINO_DEBUG_NODE")) {
                for (size_t i = 0; i < ov_output_names_local.size(); i++) {
                    const auto output_tensor = infer_request->get_output_tensor(i);
                    print_output_tensor_info(ov_output_names_local[i], output_tensor, output_tensor.data());
                }
            }
            dump_ov_outputs_raw(infer_request, ov_output_names_local, "prefill");
        }
        infer_end_time = ggml_time_us();
    } else {
        for (size_t i = 0; i < ov_input_names_local.size(); i++) {
            const auto & param_name = ov_input_names_local[i];
            auto input_tensor = get_ov_input_tensor_static_decode(ggml_decoder, param_name);
            infer_request->set_input_tensor(i, input_tensor);

            if (ggml_openvino_getenv_int("GGML_OPENVINO_DEBUG_INPUT")) {
                const auto input_tensor = infer_request->get_input_tensor(i);
                print_input_tensor_info(param_name, input_tensor);
            }
        }

        for (size_t i = 0; i < ov_output_names_local.size(); i++) {
            const auto & model_outputs = ggml_decoder->get_model_outputs();
            auto model_output_it = model_outputs.find(ov_output_names_local[i]);
            if (model_output_it == model_outputs.end()) {
                continue;
            }
            auto * ggml_tensor = model_output_it->second;
            if (ggml_nbytes(ggml_tensor) == 0) {
                continue;
            }
            auto output_tensor = create_ov_output_tensor(ggml_decoder, infer_request, i, ggml_tensor);
            infer_request->set_output_tensor(i, output_tensor);
        }

        ov_raw_infer_start = ggml_time_us();
        try {
            infer_request->infer();
        } catch (const std::exception & e) {
            // Device budget: a freshly compiled level graph cannot coexist with the prefill on
            // the device (defect-7 family; nondeterministic with device fragmentation). Evict
            // every level graph, flip the process-wide kill-switch and retry this step on the
            // full-ctx decode graph. One-shot: the retry re-enters with decode_level == 0.
            if (decode_level > 0 && strstr(e.what(), "UNINITIALIZED") != nullptr) {
                GGML_LOG_WARN("ggml-openvino: decode level %d graph hit the device budget "
                              "(ZE_RESULT_ERROR_UNINITIALIZED); disabling decode levels and retrying "
                              "this step on the full-ctx decode graph\n", decode_level);
                g_decode_levels_disabled.store(true);
                {
                    std::lock_guard<std::mutex> map_lock(r_ctx->ctx_mutex);
                    r_ctx->infer_request_cache_decode_levels.clear();
                    if (entry != nullptr) {
                        entry->ptr_decode_levels.clear();
                    }
                }
                lock.unlock();
                return ov_graph_compute_static(cgraph, r_ctx);
            }
            throw;
        }
        infer_end_time = ggml_time_us();
        ov_raw_infer_total = infer_end_time - ov_raw_infer_start;

        if (ggml_openvino_getenv_int("GGML_OPENVINO_DEBUG_OUTPUT") ||
            ggml_openvino_getenv_str("GGML_OPENVINO_DEBUG_NODE")) {
            for (size_t i = 0; i < ov_output_names_local.size(); i++) {
                const auto output_tensor = infer_request->get_output_tensor(i);
                print_output_tensor_info(ov_output_names_local[i], output_tensor, output_tensor.data());
            }
        }
        dump_ov_outputs_raw(infer_request, ov_output_names_local, "decode");
        dump_ov_profiling_info(*infer_request);
    }

    if (ggml_openvino_getenv_int("GGML_OPENVINO_PROFILING")) {
        GGML_LOG_INFO("\nGGML OpenVINO Backend: \n");
        GGML_LOG_INFO("  - Graph decoder time: %.3f ms \n", (decoder_end_time - start_time) / 1000.0);
        if (!cache_hit) {
            GGML_LOG_INFO("  - Graph conversion time: %.3f ms \n", (conversion_end_time - decoder_end_time) / 1000.0);
            GGML_LOG_INFO("  - Graph compile time: %.3f ms \n", (compile_end_time - conversion_end_time) / 1000.0);
        }
        GGML_LOG_INFO("  - Graph inference time: %.3f ms \n", (infer_end_time - compile_end_time) / 1000.0);
        GGML_LOG_INFO("  - OV raw infer time: %.3f ms \n", ov_raw_infer_total / 1000.0);
    }

    return GGML_STATUS_SUCCESS;
}
}  // namespace

// Nodes on the unselected branches of ggml_build_forward_select() stay in the graph but must not be
// computed. Keep them out of the OV model, or their inputs become parameters with fixed shapes.
static ggml_cgraph * get_compute_graph(ggml_cgraph * cgraph, ov_runtime_context & r_ctx) {
    auto is_skipped = [](const ggml_tensor * node) {
        return node->op != GGML_OP_NONE && !(node->flags & GGML_TENSOR_FLAG_COMPUTE);
    };
    if (std::none_of(cgraph->nodes, cgraph->nodes + cgraph->n_nodes, is_skipped)) {
        return cgraph;
    }
    auto & compute = r_ctx.compute_graphs[cgraph];
    compute.nodes.clear();
    std::copy_if(cgraph->nodes, cgraph->nodes + cgraph->n_nodes, std::back_inserter(compute.nodes),
                 [&](const ggml_tensor * node) { return !is_skipped(node); });
    compute.graph = *cgraph;
    compute.graph.nodes = compute.nodes.data();
    compute.graph.n_nodes = (int) compute.nodes.size();
    return &compute.graph;
}

// Both execution paths use two cache levels:
// 1. Reuse this backend's decoder/request via graph_key and compatibility checks.
// 2. On a local miss, look up compiled_graph_key in the shared compilation cache,
//    compile if needed, then create a private request from the compiled model.
// The shared lock covers compilation and frontend cleanup, never inference.
enum ggml_status ov_graph_compute(ggml_cgraph * cgraph, ggml_backend_t backend) {
    ggml_backend_openvino_context * ctx = (ggml_backend_openvino_context *) backend->context;
    try {
        if (ggml_openvino_getenv_int("GGML_OPENVINO_DUMP_CGRAPH")) {
            std::string filename = "cgraph_ov.txt";
            GgmlOvDecoder::dump_cgraph(cgraph, filename);
        }

        const auto is_static = ggml_openvino_is_npu() || ggml_openvino_getenv_int("GGML_OPENVINO_FORCE_STATIC");

        GGML_ASSERT(ctx->runtime_context != nullptr);
        std::shared_ptr<ov_runtime_context> r_ctx = std::static_pointer_cast<ov_runtime_context>(ctx->runtime_context);
        std::lock_guard<std::mutex> execution_lock(r_ctx->execution_mutex);
        cgraph = get_compute_graph(cgraph, *r_ctx);

        return is_static ? ov_graph_compute_static(cgraph, r_ctx) : ov_graph_compute_dynamic(cgraph, r_ctx);
    } catch (const ov::Exception & e) {
        GGML_LOG_ERROR("GGML OpenVINO backend ov::Exception: %s\n", e.what());
        return GGML_STATUS_FAILED;
    } catch (const std::exception & e) {
        GGML_LOG_ERROR("GGML OpenVINO backend std::exception: %s\n", e.what());
        return GGML_STATUS_FAILED;
    } catch (...) {
        GGML_LOG_ERROR("GGML OpenVINO backend unknown exception\n");
        return GGML_STATUS_FAILED;
    }
}

// Detect whether a cgraph is a split subgraph or not.
// Step 1 compares each node's recorded use_count with actual fan-out references in node->src.
// Step 2 verifies that node inputs come from model nodes/weights/leafs; external sources imply split.
bool is_model_splitted(ggml_cgraph * cgraph) {
    static const bool fallback_enabled = ggml_openvino_getenv_int("GGML_OPENVINO_ENABLE_FALLBACK") != 0;
    if (!fallback_enabled) {
        return false;
    }

    // Backend op tests execute each node through ggml_graph_view(), which preserves the original
    // graph use_counts while exposing only one node. Treat those single-node views as regular
    // naive graphs so intermediate ops do not look like split-model fragments.
    if (cgraph->n_nodes <= 1 && cgraph->n_leafs == 0) {
        return false;
    }

    // check the nodes of the model are used by the following nodes, through compare the node's use count and the count of nodes that use it as input. If does not match, return true, else return false.
    for (int i = 0; i < cgraph->n_nodes; i++) {
        ggml_tensor * node = cgraph->nodes[i];
        int use_count = cgraph->use_counts[ggml_hash_find(&cgraph->visited_hash_set, node)];
        // TODO: this is a workround for the tests case from llama.cpp, fix should from the root cause in the future.
        if ((cgraph->n_nodes <= 1 && use_count == 0) ||
            (cgraph->n_nodes <= 1 && node->op == GGML_OP_VIEW && use_count == 1 && node->src[0] != nullptr &&
             node->src[0]->op == GGML_OP_NONE)) {
            return false;
        }
        if (cgraph->n_nodes == 1 &&
            (cgraph->nodes[0]->op == GGML_OP_TRANSPOSE || cgraph->nodes[0]->op == GGML_OP_PERMUTE)) {
            return false;
        }
        int input_use_count = 0;
        for (int j = 0; j < cgraph->n_nodes; j++) {
            ggml_tensor * other_node = cgraph->nodes[j];
            for (int k = 0; k < GGML_MAX_SRC; k++) {
                if (other_node->src[k] == node) {
                    input_use_count++;
                }
            }
        }
        if (use_count != input_use_count && node->op != GGML_OP_NONE) {
            return true;
        }
    }
    // if all nodes's src node's src is not come from the nodes in the model, we think the model is splitted. This is a complementary check for the above check, because for some special case like the output node is not used by any node, the use count and input use count are both 0, we can not determine whether the model is splitted or not just based on the first check.
    // Only weight-name membership is needed below. With GGML_OPENVINO_REDUCE_COMPILE_MEM
    // use the name-only collector (no weight extraction); otherwise keep the original
    // behavior of building (naive) weight nodes and take their names.
    std::set<std::string> model_weights;
    if (ggml_openvino_reduce_compile_mem_enabled()) {
        model_weights = GgmlOvDecoder::collect_weight_names(cgraph);
    } else {
        for (const auto & kv : GgmlOvDecoder::create_weight_nodes(cgraph, true)) {
            model_weights.insert(kv.first);
        }
    }
    std::set<ggml_tensor *> model_nodes(cgraph->nodes, cgraph->nodes + cgraph->n_nodes);
    // leaf nodes
    std::set<ggml_tensor *> model_leafs(cgraph->leafs, cgraph->leafs + cgraph->n_leafs);
    for (int i = 0; i < cgraph->n_nodes; i++) {
        ggml_tensor * node = cgraph->nodes[i];
        for (int j = 0; j < GGML_MAX_SRC; j++) {
            ggml_tensor * src = node->src[j];
            // the src is also not the model weights, we think the model is splitted.
            // the src is also not in model leafs, we think the model is splitted.
            if (src != nullptr && model_nodes.find(src) == model_nodes.end() &&
                model_weights.find(std::string(src->name)) == model_weights.end() && !model_leafs.empty() == false &&
                model_leafs.find(src) == model_leafs.end()) {
                if (GgmlOvDecoder::is_inp_tok(src, node)) {
                    return false;
                }
                return true;
            }
        }
    }
    return false;
}

bool is_naive(ggml_cgraph * cgraph) {
    constexpr int naive_graph_size_threshold = 20;
    int count = 0;
    for (int i = 0; i < cgraph->n_nodes; i++) {
        if (cgraph->nodes[i]->op != GGML_OP_NONE) {
            count++;
        }
    }
    return count < naive_graph_size_threshold;
}

size_t checksum(const void * data, size_t size) {
    const uint8_t * bytes = static_cast<const uint8_t *>(data);
    size_t sum = 0;
    for (size_t i = 0; i < size; ++i) {
        sum += (uint8_t) i;
        sum += bytes[i];
    }
    return sum;
}

bool save_ggml_tensor_data_to_txt(const ggml_tensor * tensor, const std::string & file_path) {
    if (tensor == nullptr || tensor->data == nullptr) {
        return false;
    }

    std::ofstream out(file_path);
    if (!out.is_open()) {
        return false;
    }

    const size_t n = ggml_nelements(tensor);
    out << "name: " << tensor->name << ", type: " << ggml_type_name(tensor->type) << ", shape: [" << tensor->ne[0]
        << ", " << tensor->ne[1] << ", " << tensor->ne[2] << ", " << tensor->ne[3] << "]" << ", elements: " << n
        << ", data:" << '\n';

    switch (tensor->type) {
    case GGML_TYPE_F32: {
        const auto * data = static_cast<const float *>(tensor->data);
        for (size_t i = 0; i < n; ++i) {
            out << data[i] << '\n';
        }
        break;
    }
    case GGML_TYPE_F16: {
        const auto * data = static_cast<const ggml_fp16_t *>(tensor->data);
        for (size_t i = 0; i < n; ++i) {
            out << ggml_fp16_to_fp32(data[i]) << '\n';
        }
        break;
    }
    case GGML_TYPE_BF16: {
        const auto * data = static_cast<const ggml_bf16_t *>(tensor->data);
        for (size_t i = 0; i < n; ++i) {
            out << ggml_bf16_to_fp32(data[i]) << '\n';
        }
        break;
    }
    case GGML_TYPE_I32: {
        const auto * data = static_cast<const int32_t *>(tensor->data);
        for (size_t i = 0; i < n; ++i) {
            out << data[i] << '\n';
        }
        break;
    }
    case GGML_TYPE_I64: {
        const auto * data = static_cast<const int64_t *>(tensor->data);
        for (size_t i = 0; i < n; ++i) {
            out << data[i] << '\n';
        }
        break;
    }
    default:
        out << "unsupported tensor type for text dump" << '\n';
        return false;
    }

    return true;
}

void print_input_tensor_info(const std::string & name, const ov::Tensor & tensor) {
    std::cout << "Input name: " << name << ", Input shape: " << tensor.get_shape() << ", Address: " << tensor.data()
              << '\n';
    switch (tensor.get_element_type()) {
    case ov::element::f32: {
        if (name.find("self_kq_mask") == std::string::npos && name.find("KQ_mask") == std::string::npos) {
            std::cout << *(tensor.data<float>()) << '\n';
        } else {
            size_t rows = tensor.get_shape()[2];
            size_t cols = tensor.get_shape()[3];
            const float * data = tensor.data<float>();
            for (size_t i = 0; i < rows; ++i) {
                for (size_t j = 0; j < cols; ++j) {
                    float val = data[i * cols + j];
                    if (std::isinf(val) && val < 0) {
                        std::cout << std::setw(5) << "-inf";
                    } else {
                        std::cout << std::setw(5) << val;
                    }
                }
                std::cout << '\n';
            }
        }

        break;
    }
    case ov::element::f16:
        std::cout << *(tensor.data<ov::float16>()) << '\n';
        break;
    case ov::element::i32:
        for (size_t i = 0; i < tensor.get_size(); ++i) {
            std::cout << tensor.data<int32_t>()[i] << ' ';
        }
        std::cout << '\n';
        break;
    case ov::element::i64:
        for (size_t i = 0; i < tensor.get_size(); ++i) {
            std::cout << tensor.data<int64_t>()[i] << ' ';
        }
        std::cout << '\n';
        break;
    default:
        break;
    }
}

void print_output_tensor_info(const std::string & name, const ov::Tensor & tensor, const void * output_dst) {
    std::cout << "Output name: " << name << ", Output shape: " << tensor.get_shape() << ", Address: " << output_dst
              << '\n';

    auto print_float_stats = [](const std::string & type_name, size_t size, auto get_value) {
        if (size == 0) {
            return;
        }

        float first = get_value(0);
        float min = first;
        float max = first;
        double sum = first;

        for (size_t i = 1; i < size; ++i) {
            float v = get_value(i);
            min = std::min(v, min);
            max = std::max(v, max);
            sum += v;
        }
        double mean = sum / size;

        std::cout << std::right << std::setw(6) << type_name << std::right << std::setw(12) << "First" << std::setw(12)
                  << "Min" << std::setw(12) << "Max" << std::setw(12) << "Mean" << '\n';
        std::cout << std::right << std::setw(6) << "" << std::right << std::setw(12) << first << std::setw(12) << min
                  << std::setw(12) << max << std::setw(12) << mean << '\n';
    };

    switch (tensor.get_element_type()) {
    case ov::element::f32: {
        const float * data = tensor.data<float>();
        size_t size = tensor.get_size();
        print_float_stats("[f32]", size, [data](size_t i) { return data[i]; });
        break;
    }
    case ov::element::f16: {
        const ov::float16 * data = tensor.data<ov::float16>();
        size_t size = tensor.get_size();
        print_float_stats("[f16]", size, [data](size_t i) { return static_cast<float>(data[i]); });
        break;
    }
    default:
        break;
    }
}

const ggml_tensor * get_inp_pos_tensor(ggml_cgraph * cgraph) {
    for (int i = 0; i < cgraph->n_nodes; ++i) {
        auto * op = cgraph->nodes[i];
        for (int j = 0; j < GGML_MAX_SRC; ++j) {
            auto * src = op->src[j];
            if (src == nullptr) {
                break;
            }
            if (GgmlOvDecoder::is_inp_pos(src, op)) {
                return src;
            }
        }
    }
    GGML_LOG_ERROR("get_inp_pos_tensor: inp_pos not found in cgraph");
    throw std::runtime_error("get_inp_pos_tensor: inp_pos not found in cgraph");
}

int64_t get_inp_pos_n_tokens(ggml_cgraph * cgraph, const ggml_tensor * inp_pos) {
    // IMROPE stacks n_planes (t/h/w/e) position planes into inp_pos, so ne[0] is
    // n_planes * n_tokens. Callers that need a token count must divide the planes out.
    int n_planes = 1;
    for (int i = 0; i < cgraph->n_nodes; ++i) {
        auto * op = cgraph->nodes[i];
        for (int j = 0; j < GGML_MAX_SRC; ++j) {
            if (op->src[j] == inp_pos) {
                n_planes = GgmlOvDecoder::get_inp_pos_n_planes(op);
                break;
            }
        }
    }
    return inp_pos->ne[0] / n_planes;
}

bool get_is_prefill(ggml_cgraph * cgraph, const ggml_tensor * inp_pos) {
    return get_inp_pos_n_tokens(cgraph, inp_pos) > 1;
}
