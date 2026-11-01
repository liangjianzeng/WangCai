#include "../node_context.h"
#include "ggml-impl.h"
#include "../op_table.h"
#include "../utils.h"

#include <cassert>
#include <cstdint>
#include <memory>
#include <openvino/core/node.hpp>
#include <openvino/op/add.hpp>
#include <openvino/op/unsqueeze.hpp>
#include <openvino/op/scatter_nd_update.hpp>
#include <openvino/op/slice.hpp>
#include <openvino/core/node_output.hpp>
#include <openvino/core/type.hpp>
#include <openvino/frontend/exception.hpp>
#include <openvino/op/broadcast.hpp>
#include <openvino/op/concat.hpp>
#include <openvino/op/constant.hpp>
#include <openvino/op/convert.hpp>
#include <openvino/op/gather.hpp>
#include <openvino/op/mod.hpp>
#include <openvino/op/reshape.hpp>
#include <openvino/op/scatter_elements_update.hpp>
#include <openvino/op/scatter_update.hpp>
#include <openvino/op/shape_of.hpp>
#include <openvino/op/slice.hpp>
#include <openvino/op/squeeze.hpp>
#include <openvino/op/transpose.hpp>
#include <vector>

namespace ov {
namespace frontend {
namespace ggml {
namespace op {

OutputVector translate_set_rows(const NodeContext & context) {
    num_inputs_check(context, 3, 3);

    auto data = process_view_input_new(context, 0);
    auto indices = process_view_input_new(context, 1);
    auto dst = process_view_input_new(context, 2);

    data = std::make_shared<ov::op::v0::Convert>(data, context.get_output_type());

    const auto indices_shape = context.get_input_shape(1);
    const bool multidim_indices = indices_shape.rank().is_static() &&
                                  indices_shape.rank().get_length() == 4 &&
                                  ((indices_shape[1].is_static() && indices_shape[1].get_length() > 1) ||
                                   (indices_shape[2].is_static() && indices_shape[2].get_length() > 1));

    auto axes = ov::op::v0::Constant::create(ov::element::i64, ov::Shape{}, {2});

    Output<Node> res;
    if (context.is_stateful()) {
        int concat_axis = 1;
        int64_t dim2 = dst.get_partial_shape()[2].get_length();
        int64_t dim3 = dst.get_partial_shape()[3].get_length();
        data = std::make_shared<ov::op::v1::Reshape>(
            data, ov::op::v0::Constant::create(ov::element::i64, {4}, {(int64_t) 1, (int64_t) -1, dim2, dim3}), false);
        res = std::make_shared<ov::op::v0::Concat>(OutputVector{dst, data}, concat_axis);
    } else if (multidim_indices) {
        auto updates_shape = std::make_shared<ov::op::v3::ShapeOf>(data, ov::element::i64);

        auto indices_rank3 = std::make_shared<ov::op::v0::Squeeze>(
            indices, ov::op::v0::Constant::create(ov::element::i64, {1}, {0}));
        auto one = ov::op::v0::Constant::create(ov::element::i64, {1}, {1});
        auto indices_rank4_shape = std::make_shared<ov::op::v0::Concat>(OutputVector{get_dimensions(updates_shape, {0, 1, 2}), one}, 0);
        auto indices_rank4 = std::make_shared<ov::op::v1::Reshape>(indices_rank3, indices_rank4_shape, false);
        auto broadcasted_indices = std::make_shared<ov::op::v3::Broadcast>(indices_rank4, updates_shape);

        res = std::make_shared<ov::op::v3::ScatterElementsUpdate>(dst, broadcasted_indices, data, axes);
    } else {
        auto row_size = context.get_input_shape(2)[3].get_length();
        std::shared_ptr<ov::Node> ind_squeezed = std::make_shared<ov::op::v0::Squeeze>(
            indices, ov::op::v0::Constant::create(ov::element::i64, {3}, {0, 1, 2}));
        // The static decode graph keeps the two interleaved-SWA write-index inputs merged into
        // one parameter: NPUW compiles that graph's numerics correctly only in the one-parameter
        // shape it was first validated with, and adding the second (value-equal below the ring)
        // parameter makes every decode-step output come back NaN on the device -- while the same
        // rename on the prefill graph, and on both graphs of the dynamic path, is harmless. See
        // the rename's comment in get_tensor_graph_input_ov_name() (ggml-decoder.cpp).
        //
        // The merged parameter carries the full-attention cache's cell ids, which outgrow the
        // SWA ring's row count once the sequence passes n_swa -- the exact out-of-bounds scatter
        // this file used to crash on. Wrap the index in a Mod against the destination's row
        // count: the identity for every id a decode step can hold (cells stay below -c), the
        // ring wrap for the SWA destinations past it.
        const auto & idx_name = context.get_input_names().at(1);
        const auto dst_shape = context.get_input_shape(2);
        if (context.is_static() && !context.is_prefill() && dst_shape[2].is_static() &&
            (idx_name == "attn_inp_k_idxs" || idx_name == "attn_inp_v_idxs")) {
            const auto dst_rows = dst_shape[2].get_length();
            ind_squeezed = std::make_shared<ov::op::v1::Mod>(
                ind_squeezed, ov::op::v0::Constant::create(ov::element::i64, ov::Shape{}, {dst_rows}));
        }
        auto data_reshaped = std::make_shared<ov::op::v1::Reshape>(
            data,
            ov::op::v0::Constant::create(ov::element::i64, {4},
                                         {(int64_t) 1, (int64_t) 1, (int64_t) -1, (int64_t) row_size}),
            false);
        if (context.is_static() && dst_shape[2].is_static()) {
            // The NPU device's lowering of ScatterUpdate (through the NPUW pipeline) fails to
            // commit the write for index 0: the static prefill's iota [0..n) loses exactly its
            // 0, leaving the context-init decode warmup's dummy K/V in cache row 0 (rows 1..n
            // land; decode indices are nonzero and land; the same translation is correct on
            // CPU). ScatterND takes a different lowering path, so route the prefill write
            // through it: indices become [N,3] rows (0,0,idx) selecting full [512] rows of the
            // [1,1,rows,D] cache, updates become [N,D].
            //
            // 2026-11-01: extended to the static decode graph. Graph-output dumps proved the
            // decode K value correct pre-write (dbg_k post-norm cos 0.997+ on NPU) while the
            // cached row keeps correct values only in the even 128-blocks (h0/h2) and stale,
            // build-independent garbage in the odd blocks (h1/h3) -- the decode ScatterUpdate
            // lowering commits only half of each 512-element K row, and the correct odd-head
            // blocks appear nowhere else in the cache. V is unaffected (same op, same shapes,
            // only the dst parameter differs); prefill writes via ScatterND were complete.
            // This write defect is the answer-quality root cause: attention reads the garbled
            // BOS row at every decode step.
            const int64_t dst_rows = dst_shape[2].get_length();
            const int64_t d = dst_shape[3].get_length();
            auto idx_i64 = std::make_shared<ov::op::v0::Convert>(ind_squeezed, ov::element::i64);
            auto n_rows = std::make_shared<ov::op::v3::ShapeOf>(idx_i64, ov::element::i64);
            auto two = ov::op::v0::Constant::create(ov::element::i64, ov::Shape{1}, {2});
            auto prefix = std::make_shared<ov::op::v3::Broadcast>(
                ov::op::v0::Constant::create(ov::element::i64, ov::Shape{1, 2}, std::vector<int64_t>{0, 0}),
                std::make_shared<ov::op::v0::Concat>(OutputVector{n_rows, two}, 0));
            auto idx_col = std::make_shared<ov::op::v0::Unsqueeze>(idx_i64, ov::op::v0::Constant::create(ov::element::i64, {1}, {1}));
            auto nd_idx = std::make_shared<ov::op::v0::Concat>(OutputVector{prefix, idx_col}, 1);
            auto upd_flat = std::make_shared<ov::op::v1::Reshape>(
                data_reshaped,
                ov::op::v0::Constant::create(ov::element::i64, ov::Shape{2}, std::vector<int64_t>{-1, d}), false);
            res = std::make_shared<ov::op::v3::ScatterNDUpdate>(dst, nd_idx, upd_flat);
        } else {
            res = std::make_shared<ov::op::v3::ScatterUpdate>(dst, ind_squeezed, data_reshaped, axes);
        }
    }

    auto dst_reshape = ov::as_type_ptr<ov::op::v1::Reshape>(dst.get_node_shared_ptr());
    if (!multidim_indices && dst_reshape) {
        // Fix the case of multiple sequences, reshape back to original shape [1, n_seq, ctx_per_seq, emb]
        // ctx_per_seq is not fixed due to llama-bench compatibility
        auto dst_shape_partial = dst_reshape->get_input_partial_shape(0);
        std::vector<int64_t> dst_shape = {dst_shape_partial[0].get_length(), dst_shape_partial[1].get_length(),
                                          dst_shape_partial[2].is_static() ? dst_shape_partial[2].get_length() : -1,
                                          dst_shape_partial[3].get_length()};
        res = std::make_shared<ov::op::v1::Reshape>(res, ov::op::v0::Constant::create(ov::element::i64, {4}, dst_shape),
                                                    false);
    }
    return rename_outputs_with_suffix({res}, context.get_name());
}

}  // namespace op
}  // namespace ggml
}  // namespace frontend
}  // namespace ov
