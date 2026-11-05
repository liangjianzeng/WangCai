#include "../node_context.h"
#include "../op_table.h"
#include "../translate_session.h"
#include "../utils.h"
#include "ggml-openvino/ggml-openvino-extra.h"

#include <cstdint>
#include <memory>
#include <openvino/core/node.hpp>
#include <openvino/core/node_output.hpp>
#include <openvino/op/add.hpp>
#include <openvino/op/broadcast.hpp>
#include <openvino/op/concat.hpp>
#include <openvino/op/constant.hpp>
#include <openvino/op/convert.hpp>
#include <openvino/op/multiply.hpp>
#include <openvino/op/reshape.hpp>
#include <openvino/op/slice.hpp>
#include <openvino/op/split.hpp>
#include <openvino/op/subtract.hpp>
#include <openvino/op/unsqueeze.hpp>
#include <openvino/op/variadic_split.hpp>
#include <vector>

namespace ov {
namespace frontend {
namespace ggml {
namespace op {

OutputVector translate_rope(const NodeContext & context) {
    num_inputs_check(context, 2, 3);

    int op_case = context.get_op_case();

    ov::Output<Node> res;

    auto data_node = process_view_input_new(context, 0).get_node_shared_ptr();
    auto output_shape = context.get_output_shape().to_shape();
    int32_t * op_params = context.get_output_op_params();
    const int mode = op_case;
    const int64_t head_dim = static_cast<int64_t>(output_shape[3]);
    const int64_t configured_n_dims = static_cast<int64_t>(op_params[1]);
    const int64_t n_dims = configured_n_dims == 0 ? head_dim : configured_n_dims;
    const int64_t n_offs = static_cast<int64_t>(op_params[15]);

    constexpr int TYPE_NORMAL = 0;
    constexpr int TYPE_NEOX = 1;
    constexpr int TYPE_IMROPE = 2;
    constexpr int TYPE_VISION = 3;
    constexpr int TYPE_MROPE = 4;

    Output<Node> cos_theta_node;
    Output<Node> sin_theta_node;
    if (context.has_input("rope_cos")) {
        cos_theta_node = context.get_input("rope_cos");
        sin_theta_node = context.get_input("rope_sin");
    } else {
        std::string cache_key = "rope_sin_cos";
        for (int i = 0; i < 15; i++) {
            cache_key += "_" + std::to_string(op_params[i]);
        }
        if (context.get_input_size() == 3) {
            cache_key += "_ff_" + context.get_input_names()[2];
        }
        if (context.has_input(cache_key + "_cos")) {
            cos_theta_node = context.get_input(cache_key + "_cos");
            sin_theta_node = context.get_input(cache_key + "_sin");
        } else {
            auto inp_pos = context.get_input(1).get_node_shared_ptr();
            std::shared_ptr<ov::Node> rope_freqs_weight;
            if (context.get_input_size() == 3) {
                rope_freqs_weight = context.get_input(2).get_node_shared_ptr();
            }
            auto sin_cos = make_sin_cos(op_params, inp_pos, rope_freqs_weight, mode, false, head_dim);
            sin_theta_node = sin_cos.first;
            cos_theta_node = sin_cos.second;
            context.put_shared(cache_key + "_cos", cos_theta_node);
            context.put_shared(cache_key + "_sin", sin_theta_node);
        }
    }

    auto output_type = context.get_output_type();
    // P14d (2026-11-04): the default lowering lifts the f16 GEMV result to f32, computes the
    // mul-mul-add there and converts back -- and that f32 domain is what pins the rope chain
    // to Shave (P14 re-profile, 4B decode step: the 72 final rope Adds cost 15-17 ms each on
    // Shave ~= 22% of the step; 1.7B prefill: the Shave Multiply family ~= 31%). With
    // GGML_OPENVINO_ROPE_F16=1 an f16 data/out rope computes fully in f16: the f32 sin/cos
    // tables enter f16 once per graph inside the shared P14b table-side chain, the data side
    // has no converts at all. Env-gated until the accuracy gates (three-question acceptance,
    // long-generation consistency) have blessed it for default-on.
    static const bool rope_f16_enabled = ggml_openvino_getenv_int("GGML_OPENVINO_ROPE_F16") > 0;
    const bool compute_f16 = rope_f16_enabled && !context.is_stateful() &&
                             data_node->get_element_type() == ov::element::f16 &&
                             output_type == ov::element::f16;
    if (!compute_f16 && data_node->get_element_type() != ov::element::f32) {
        data_node = std::make_shared<ov::op::v0::Convert>(data_node, ov::element::f32);
    }

    const int64_t total_rope_dims = (mode == TYPE_VISION) ? (2 * n_dims) : n_dims;
    FRONT_END_OP_CONVERSION_CHECK(n_offs >= 0 && (n_offs % 2 == 0),
                                  "ROPE expects non-negative even n_offs");
    FRONT_END_OP_CONVERSION_CHECK(n_dims > 0 && total_rope_dims + n_offs <= head_dim && (n_dims % 2 == 0),
                                  "ROPE expects even n_dims with total_rope_dims + n_offs <= head_dim");

    // RoPEFusionFlux requires rank_equals(4) on x, t_cos and t_sin. The cos/sin
    // tables are already built rank-4 ([1, S, 1, head_size/2]) for both modes. In
    // stateful mode the data arrives rank-3 ([S, n_heads, head_size]), so lift it
    // to rank-4 ([1, S, n_heads, head_size]) here. Stateful RoPE already produced
    // rank-4 output, so downstream attention is unaffected.
    if (context.is_stateful()) {
        const int64_t batch = static_cast<int64_t>(output_shape[0]);
        auto r4_shape = ov::op::v0::Constant::create(
            ov::element::i64, {4},
            std::vector<int64_t>{batch, -1, (int64_t) output_shape[2], (int64_t) output_shape[3]});
        data_node = std::make_shared<ov::op::v1::Reshape>(data_node, r4_shape, false);
    }
    // For TYPE_NORMAL rope (both stateful and stateless) we emit the Flux-style
    // interleaved pattern below so the GPU plugin's RoPEFusionFlux matcher folds it
    // into ov::op::internal::RoPE.
    if (mode == TYPE_NORMAL) {
        auto axis_last = ov::op::v0::Constant::create(ov::element::i64, {1}, {-1});
        auto step_one = ov::op::v0::Constant::create(ov::element::i64, {1}, {1});

        const int64_t batch = static_cast<int64_t>(output_shape[0]);
        const int64_t n_heads = static_cast<int64_t>(output_shape[2]);
        const int64_t half = n_dims / 2;
        auto rot_start = ov::op::v0::Constant::create(ov::element::i64, {1}, {n_offs});
        auto rot_end = ov::op::v0::Constant::create(ov::element::i64, {1}, {n_offs + n_dims});
        auto rot_data = std::make_shared<ov::op::v8::Slice>(data_node, rot_start, rot_end, step_one, axis_last);

        auto neg_one_f = ov::op::v0::Constant::create(data_node->get_element_type(), ov::Shape{}, {-1.0f});

        auto paired_shape = ov::op::v0::Constant::create(
            ov::element::i64, {5}, std::vector<int64_t>{batch, -1, n_heads, half, 2});
        auto x_paired = std::make_shared<ov::op::v1::Reshape>(rot_data, paired_shape, false);

        auto split_axis = ov::op::v0::Constant::create(ov::element::i64, ov::Shape{}, {-1});
        auto data_split = std::make_shared<ov::op::v1::Split>(x_paired, split_axis, 2);
        Output<Node> x0 = data_split->outputs()[0];
        Output<Node> x1 = data_split->outputs()[1];

        auto x1_neg = std::make_shared<ov::op::v1::Multiply>(x1, neg_one_f);
        auto x_rotated_paired = std::make_shared<ov::op::v0::Concat>(ov::OutputVector{x1_neg, x0}, -1);

        auto flat_shape =
            ov::op::v0::Constant::create(ov::element::i64, {4}, std::vector<int64_t>{batch, -1, n_heads, n_dims});
        auto x_rotated =
            std::make_shared<ov::op::v1::Reshape>(x_rotated_paired, flat_shape, false);

        // Expand cos/sin from [..., n_dims/2] to [..., n_dims] by repeating each
        // entry twice. Use special_zero on the final Reshape so the seq dim passes
        // through dynamically. Final rank is 4 to satisfy the matcher's predicate.
        //
        // P14b (2026-11-04): the expansion depends only on the shared table (make_sin_cos
        // via put_shared, or one explicit rope_cos/rope_sin graph input) and `half`, so it
        // is memoized per graph -- every rope node used to rebuild it (1.7B prefill profiled
        // Multiply n=196 rope family, 27%). Same session-memo pattern as P14a's scatter-index
        // chain; hit path shares the identical nodes (the data-side half below stays per node).
        Output<Node> cos_full;
        Output<Node> sin_full;
        {
            TranslateSession::RopeCSKey memo_key{cos_theta_node.get_node(), half, 0, true, compute_f16};
            auto * session = context.get_translate_session();
            if (session) {
                auto & memo = session->shared_rope_cos_sin();
                auto it = memo.find(memo_key);
                if (it != memo.end()) {
                    cos_full = it->second.first;
                    sin_full = it->second.second;
                }
            }
            if (!cos_full.get_node()) {
                auto expand_cos_sin = [&](const Output<Node>& cs) {
                    auto cs_unsq = std::make_shared<ov::op::v0::Unsqueeze>(
                        cs, ov::op::v0::Constant::create(ov::element::i64, {1}, {-1}));
                    auto bcast_target = ov::op::v0::Constant::create(
                        ov::element::i64, {5}, std::vector<int64_t>{1, 1, 1, half, 2});
                    auto bcast = std::make_shared<ov::op::v3::Broadcast>(
                        cs_unsq, bcast_target, ov::op::BroadcastType::BIDIRECTIONAL);
                    auto flat =
                        ov::op::v0::Constant::create(ov::element::i64, {4}, std::vector<int64_t>{0, 0, 0, n_dims});
                    return std::make_shared<ov::op::v1::Reshape>(bcast, flat, true);
                };
                Output<Node> cos_src = cos_theta_node;
                Output<Node> sin_src = sin_theta_node;
                if (compute_f16) {  // P14d: one f32->f16 convert per graph, shared (inside the memo)
                    if (cos_src.get_element_type() != ov::element::f16) {
                        cos_src = std::make_shared<ov::op::v0::Convert>(cos_src, ov::element::f16);
                    }
                    if (sin_src.get_element_type() != ov::element::f16) {
                        sin_src = std::make_shared<ov::op::v0::Convert>(sin_src, ov::element::f16);
                    }
                }
                cos_full = expand_cos_sin(cos_src);
                sin_full = expand_cos_sin(sin_src);
                if (session) {
                    session->shared_rope_cos_sin().emplace(memo_key, std::make_pair(cos_full, sin_full));
                }
            }
        }

        auto y1 = std::make_shared<ov::op::v1::Multiply>(rot_data, cos_full);
        auto y2 = std::make_shared<ov::op::v1::Multiply>(x_rotated, sin_full);
        auto rotated = std::make_shared<ov::op::v1::Add>(y1, y2);

        ov::OutputVector concat_parts;
        if (n_offs > 0) {
            auto head_start = ov::op::v0::Constant::create(ov::element::i64, {1}, {0});
            auto head_end = ov::op::v0::Constant::create(ov::element::i64, {1}, {n_offs});
            auto head = std::make_shared<ov::op::v8::Slice>(data_node, head_start, head_end, step_one, axis_last);
            concat_parts.push_back(head);
        }
        concat_parts.push_back(rotated);
        if (n_offs + n_dims < head_dim) {
            auto tail_start = ov::op::v0::Constant::create(ov::element::i64, {1}, {n_offs + n_dims});
            auto tail_end = ov::op::v0::Constant::create(ov::element::i64, {1}, {head_dim});
            auto tail = std::make_shared<ov::op::v8::Slice>(data_node, tail_start, tail_end, step_one, axis_last);
            concat_parts.push_back(tail);
        }
        if (concat_parts.size() == 1) {
            res = rotated;
        } else {
            res = std::make_shared<ov::op::v0::Concat>(concat_parts, -1);
        }
    } else if (mode == TYPE_NEOX || mode == TYPE_IMROPE || mode == TYPE_MROPE || mode == TYPE_VISION) {
        const int64_t half = (mode == TYPE_VISION) ? n_dims : (n_dims / 2);
        const int64_t rot_dims = 2 * half;

        // (P14b: the mode != TYPE_NEOX table reshape moved into the memoized table-side
        // chain below -- cos_theta_node/sin_theta_node are not read after that chain.)

        auto axis_last = ov::op::v0::Constant::create(ov::element::i64, {1}, {-1});
        auto step_one = ov::op::v0::Constant::create(ov::element::i64, {1}, {1});

        Output<Node> rot_data = data_node;
        if (n_offs > 0 || n_offs + rot_dims < head_dim) {
            auto rot_start = ov::op::v0::Constant::create(ov::element::i64, {1}, {n_offs});
            auto rot_end = ov::op::v0::Constant::create(ov::element::i64, {1}, {n_offs + rot_dims});
            rot_data = std::make_shared<ov::op::v8::Slice>(data_node, rot_start, rot_end, step_one, axis_last);
        }

        auto split_axis = ov::op::v0::Constant::create(ov::element::i64, ov::Shape{}, {3});
        auto split_lengths = ov::op::v0::Constant::create(ov::element::i64, {2}, {half, half});
        auto data_split = std::make_shared<ov::op::v1::VariadicSplit>(rot_data, split_axis, split_lengths);
        Output<Node> x1 = data_split->outputs()[0];
        Output<Node> x2 = data_split->outputs()[1];

        // P16: the rotate-half operand is a plain swap -- its sign flip lives in the shared
        // swapped-sin table (Concat(-sin1, sin2)), saving the per-node Multiply(x2, -1).
        // IEEE754: (x2 * -1) * s1 == x2 * (-s1) exactly, so this is bit-neutral.
        auto x_rotate_half = std::make_shared<ov::op::v0::Concat>(ov::OutputVector{x2, x1}, -1);

        // P14b (2026-11-04): the table-side half of this lowering -- the non-NEOX reshape,
        // the duplication Concats and the static-decode head-axis tile -- depends only on the
        // (already shared) cos/sin table, `half` and the data head count. Every rope node
        // used to rebuild all of it (4B decode: 4 table-side Concats per rope node x 72 rope
        // nodes, feeding the Add-38%/Multiply families P13 profiled); one pair per
        // (table, half, tile width, lowering) is shared per graph via the translate session.
        // The data-side half (slice/split/rotate-half and the final mul-mul-add) stays per node.
        int64_t tile_heads_n = 0;
        if (context.is_static() && !context.is_prefill() && !context.is_stateful()) {
            const auto data_ps = data_node->get_output_partial_shape(0);
            if (data_ps.rank().is_static() && data_ps.rank().get_length() == 4 &&
                data_ps[2].is_static() && data_ps[2].get_length() > 1) {
                tile_heads_n = data_ps[2].get_length();
            }
        }
        Output<Node> cos_full;
        Output<Node> sin_full;
        Output<Node> sin_swapped_full;
        {
            TranslateSession::RopeCSKey memo_key{cos_theta_node.get_node(), half, tile_heads_n, false,
                                                 compute_f16};
            auto * session = context.get_translate_session();
            if (session) {
                auto & memo = session->shared_rope_cos_sin();
                auto it = memo.find(memo_key);
                if (it != memo.end()) {
                    cos_full = it->second.first;
                    sin_full = it->second.second;
                }
                auto & swapped_memo = session->shared_rope_sin_swapped();
                auto swapped_it = swapped_memo.find(memo_key);
                if (swapped_it != swapped_memo.end()) {
                    sin_swapped_full = swapped_it->second;
                }
            }
            if (!cos_full.get_node()) {
                Output<Node> cos_t = cos_theta_node;
                Output<Node> sin_t = sin_theta_node;
                if (compute_f16) {  // P14d: one f32->f16 convert per graph, shared (inside the memo)
                    if (cos_t.get_element_type() != ov::element::f16) {
                        cos_t = std::make_shared<ov::op::v0::Convert>(cos_t, ov::element::f16);
                    }
                    if (sin_t.get_element_type() != ov::element::f16) {
                        sin_t = std::make_shared<ov::op::v0::Convert>(sin_t, ov::element::f16);
                    }
                }
                if (mode != TYPE_NEOX) {
                    auto cos_sin_shape = std::make_shared<ov::op::v0::Constant>(
                        ov::element::i64, ov::Shape{4}, std::vector<int64_t>{1, -1, 1, half});
                    cos_t = std::make_shared<ov::op::v1::Reshape>(cos_t, cos_sin_shape, true);
                    sin_t = std::make_shared<ov::op::v1::Reshape>(sin_t, cos_sin_shape, true);
                }
                cos_full = std::make_shared<ov::op::v0::Concat>(ov::OutputVector{cos_t, cos_t}, -1);
                sin_full = std::make_shared<ov::op::v0::Concat>(ov::OutputVector{sin_t, sin_t}, -1);
                // P16: the NEOX rotate-half sign flip as a shared swapped table, consumed by
                // the application side below (y2 = Concat(x2,x1) * sin_swapped).
                auto neg_sin = std::make_shared<ov::op::v1::Multiply>(
                    sin_t, ov::op::v0::Constant::create(sin_t.get_element_type(), ov::Shape{}, {-1.0f}));
                sin_swapped_full = std::make_shared<ov::op::v0::Concat>(ov::OutputVector{neg_sin, sin_t}, -1);

                // NPU device defect (static decode graphs): the numpy head-axis broadcast of the
                // [1,1,1,head/2*2] cos/sin tables onto the [1,1,n_head_kv,head] GEMV output comes back
                // with the odd KV heads garbled -- graph-output dumps show the rope input correct
                // (post-norm K cos 0.997+ vs CPU) while the rope output has h0/h2 identical and h1/h3
                // destroyed with inflated norms, at position 0 where rope must be the identity. The
                // same lowering is correct for the [1,256,4,128] prefill shape and in isolation
                // (minrepro), so tile the tables explicitly along the head axis: replication is
                // exactly what the numpy broadcast does, so this is bit-neutral wherever the device
                // is not defective.
                if (tile_heads_n > 0) {
                    auto tile_heads = [&](ov::Output<ov::Node> & t) {
                        auto ps = t.get_partial_shape();
                        if (!ps.rank().is_static() || ps.rank().get_length() != 4 || !ps[2].is_static() ||
                            ps[2].get_length() != 1) {
                            return;
                        }
                        ov::OutputVector parts;
                        for (int64_t h = 0; h < tile_heads_n; ++h) {
                            parts.push_back(t);
                        }
                        t = std::make_shared<ov::op::v0::Concat>(std::move(parts), 2);
                    };
                    tile_heads(cos_full);
                    tile_heads(sin_full);
                    tile_heads(sin_swapped_full);
                }
                if (session) {
                    session->shared_rope_cos_sin().emplace(memo_key, std::make_pair(cos_full, sin_full));
                    session->shared_rope_sin_swapped().emplace(memo_key, sin_swapped_full);
                }
            }
        }

        auto y1 = std::make_shared<ov::op::v1::Multiply>(rot_data, cos_full);
        auto y2 = std::make_shared<ov::op::v1::Multiply>(x_rotate_half, sin_swapped_full);
        auto rotated = std::make_shared<ov::op::v1::Add>(y1, y2);

        ov::OutputVector concat_parts;
        if (n_offs > 0) {
            auto head_start = ov::op::v0::Constant::create(ov::element::i64, {1}, {0});
            auto head_end = ov::op::v0::Constant::create(ov::element::i64, {1}, {n_offs});
            auto head = std::make_shared<ov::op::v8::Slice>(data_node, head_start, head_end, step_one, axis_last);
            concat_parts.push_back(head);
        }
        concat_parts.push_back(rotated);
        if (n_offs + rot_dims < head_dim) {
            auto tail_start = ov::op::v0::Constant::create(ov::element::i64, {1}, {n_offs + rot_dims});
            auto tail_end = ov::op::v0::Constant::create(ov::element::i64, {1}, {head_dim});
            auto tail = std::make_shared<ov::op::v8::Slice>(data_node, tail_start, tail_end, step_one, axis_last);
            concat_parts.push_back(tail);
        }
        if (concat_parts.size() == 1) {
            res = rotated;
        } else {
            res = std::make_shared<ov::op::v0::Concat>(concat_parts, -1);
        }
    }

    if (res.get_element_type() != output_type) {
        res = std::make_shared<ov::op::v0::Convert>(res, output_type);
    }

    return rename_outputs_with_suffix({res}, context.get_name());
}

}  // namespace op
}  // namespace ggml
}  // namespace frontend
}  // namespace ov
