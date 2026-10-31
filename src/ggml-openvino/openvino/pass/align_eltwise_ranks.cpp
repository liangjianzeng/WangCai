#include "align_eltwise_ranks.h"

#include <algorithm>
#include <numeric>
#include <openvino/op/add.hpp>
#include <openvino/op/concat.hpp>
#include <openvino/op/constant.hpp>
#include <openvino/op/divide.hpp>
#include <openvino/op/multiply.hpp>
#include <openvino/op/slice.hpp>
#include <openvino/op/sqrt.hpp>
#include <openvino/op/subtract.hpp>
#include <openvino/op/unsqueeze.hpp>
#include <openvino/pass/pattern/op/wrap_type.hpp>

namespace ov {
namespace frontend {
namespace ggml {
namespace pass {

namespace {

// True for an RMS-norm output, x * (1 / sqrt(mean(x^2) + eps)) as translate_rms_norm builds it, optionally
// scaled by the norm weight.
bool is_rms_norm_output(const ov::Output<ov::Node> & value, int depth = 1) {
    const auto * node = value.get_node();
    if (!ov::is_type<ov::op::v1::Multiply>(node)) {
        return false;
    }
    for (const auto & input : node->input_values()) {
        const auto * src = input.get_node();
        if (ov::is_type<ov::op::v1::Divide>(src) && ov::is_type<ov::op::v0::Sqrt>(src->get_input_node_ptr(1))) {
            return true;
        }
        if (depth > 0 && is_rms_norm_output(input, depth - 1)) {
            return true;
        }
    }
    return false;
}

// Materialize a Constant operand's numpy-broadcast result as one Constant with the target
// shape (numpy broadcast is exact replication, so this is bit-identical by construction).
std::shared_ptr<ov::op::v0::Constant> tile_constant_to(const std::shared_ptr<ov::op::v0::Constant> & cst,
                                                       const ov::Shape & target) {
    auto src_shape = cst->get_shape();
    while (src_shape.size() < target.size()) {
        src_shape.insert(src_shape.begin(), 1);
    }
    ov::Shape src_strides(src_shape.size(), 1);
    for (int64_t a = static_cast<int64_t>(src_shape.size()) - 2; a >= 0; --a) {
        src_strides[a] = src_strides[a + 1] * src_shape[a + 1];
    }
    ov::Shape dst_strides(target.size(), 1);
    for (int64_t a = static_cast<int64_t>(target.size()) - 2; a >= 0; --a) {
        dst_strides[a] = dst_strides[a + 1] * target[a + 1];
    }
    const auto src = cst->cast_vector<float>();
    std::vector<float> dst(ov::shape_size(target));
    for (size_t flat = 0; flat < dst.size(); ++flat) {
        size_t rem = flat;
        size_t src_idx = 0;
        for (size_t a = 0; a < target.size(); ++a) {
            const size_t idx = rem / dst_strides[a];
            rem -= idx * dst_strides[a];
            src_idx += (src_shape[a] == 1 ? 0 : idx) * src_strides[a];
        }
        dst[flat] = src[src_idx];
    }
    return ov::op::v0::Constant::create<float>(ov::element::f32, target, dst);
}

}  // namespace

AlignEltwiseOperandRanks::AlignEltwiseOperandRanks() {
    auto eltwise_m = ov::pass::pattern::wrap_type<ov::op::v1::Add, ov::op::v1::Multiply, ov::op::v1::Subtract>();

    const auto callback = [this](ov::pass::pattern::Matcher & m) {
        auto node = m.get_match_root();
        if (node->get_input_size() != 2) {
            return false;
        }

        const auto out_pshape = node->get_output_partial_shape(0);
        const auto & out_rank = out_pshape.rank();

        // NPUW broadcast-tile defect, decode graphs: for the 1-token shape [1, 1, 4, X] (all axes
        // before the 4-head axis are 1), EVERY operand implicitly broadcast along any axis comes
        // back with the odd heads garbled -- the k_norm multiply ([1,1,4,128] x [1,1,4,1] RMS
        // scale, x [1,128] weight) and RoPE ([1,1,4,64] x [1,1,1,64] cos/sin) all match the
        // pattern "heads 0/2 bit-exact, heads 1/3 destroyed, period 256 elements". The earlier
        // rank-mismatch-only version of this pass left the same-rank broadcasts (rank-4 RMS
        // scale and cos/sin) untouched -- and the defect was unchanged. Tile them ALL: unsqueeze
        // lower-rank operands, then replicate every size-1 axis (Constants get materialized to
        // the full shape; everything else gets Concat doubling) so no implicit broadcast of any
        // kind reaches the device. Prefill ([1,256,4,128]) and dynamic graphs do not match the
        // gate and are untouched.
        bool decode_shape = false;
        ov::Shape out_shape;
        if (out_rank.is_static() && out_rank.get_length() >= 2) {
            const size_t head_axis = out_rank.get_length() - 2;
            decode_shape = out_pshape[head_axis].is_static() && out_pshape[head_axis].get_length() == 4;
            for (size_t a = 0; decode_shape && a < head_axis; ++a) {
                decode_shape = out_pshape[a].is_static() && out_pshape[a].get_length() == 1;
            }
            if (decode_shape) {
                for (size_t a = 0; a < out_rank.get_length(); ++a) {
                    if (!out_pshape[a].is_static()) {
                        decode_shape = false;
                        break;
                    }
                    out_shape.push_back(out_pshape[a].get_length());
                }
            }
        }

        if (decode_shape) {
            // Restrict the tiling to the norm nodes (ggml name suffix "norm-…"): the decode
            // K/Q-branch per-head RMS scale and norm-weight multiplies. Tiling the whole
            // graph (softmax max, mask, RoPE included) NaNs the compiled decode graph on
            // the device, and the corrupt rows are exactly the decode-graph K writes
            // (h0/h2 exact, h1/h3 garbled with inflated norms) -- prefill K rows are
            // correct -- so the K/Q norm chain is the target.
            if (node->get_friendly_name().find("norm") == std::string::npos) {
                return false;
            }
            bool changed = false;
            for (size_t i = 0; i < 2; ++i) {
                // Constants stay untouched: materializing tiled weight copies created new
                // Constants outside NPUW's weight pipeline and the whole decode graph came
                // back NaN on the device. The weight broadcast ([1,128] onto [1,1,4,128])
                // is also present in the correct prefill, so it is not the suspect; the
                // activation broadcasts (RMS scale, RoPE cos/sin) are decode-specific.
                if (ov::is_type<ov::op::v0::Constant>(node->input_value(i).get_node())) {
                    continue;
                }
                auto in_pshape = node->input_value(i).get_partial_shape();
                if (!in_pshape.rank().is_static() || in_pshape.rank().get_length() > out_rank.get_length()) {
                    continue;
                }
                ov::Output<ov::Node> in = node->input_value(i);
                const int64_t rank_diff = static_cast<int64_t>(out_rank.get_length()) -
                                          static_cast<int64_t>(in_pshape.rank().get_length());
                if (rank_diff > 0) {
                    std::vector<int64_t> axes(static_cast<size_t>(rank_diff));
                    std::iota(axes.begin(), axes.end(), 0);
                    in = std::make_shared<ov::op::v0::Unsqueeze>(
                        in, ov::op::v0::Constant::create(ov::element::i64, ov::Shape{ axes.size() }, axes));
                    register_new_node(in.get_node_shared_ptr());
                    in_pshape = in.get_partial_shape();
                }
                if (!in_pshape.rank().is_static() || in_pshape.rank().get_length() != out_rank.get_length()) {
                    continue;
                }
                bool skip = false;
                std::vector<size_t> tile_axes;
                for (size_t a = 0; a < out_rank.get_length(); ++a) {
                    if (!in_pshape[a].is_static()) {
                        skip = true;
                        break;
                    }
                    const int64_t od = out_shape[a];
                    const int64_t id = in_pshape[a].get_length();
                    if (id == od) {
                        continue;
                    }
                    if (id == 1 && od > 1) {
                        tile_axes.push_back(a);
                    } else {
                        skip = true;
                        break;
                    }
                }
                if (skip || tile_axes.empty()) {
                    continue;
                }
                if (const auto cst = ov::as_type_ptr<ov::op::v0::Constant>(in.get_node_shared_ptr())) {
                    if (cst->get_element_type() == ov::element::f32 && ov::shape_size(out_shape) <= 65536) {
                        auto tiled = tile_constant_to(cst, out_shape);
                        node->input(i).replace_source_output(tiled->output(0));
                        register_new_node(tiled);
                        changed = true;
                    }
                    continue;
                }
                for (const size_t a : tile_axes) {
                    const int64_t target = static_cast<int64_t>(out_shape[a]);
                    int64_t cur = in.get_partial_shape()[a].get_length();
                    while (cur < target) {
                        ov::Output<ov::Node> next;
                        if (cur * 2 <= target) {
                            next = std::make_shared<ov::op::v0::Concat>(ov::OutputVector{in, in},
                                                                        static_cast<int64_t>(a));
                            cur *= 2;
                        } else {
                            // Tail: 2*cur would overshoot; concat a slice of width target-cur.
                            const int64_t need = target - cur;
                            auto tail = std::make_shared<ov::op::v8::Slice>(
                                in,
                                ov::op::v0::Constant::create(ov::element::i64, ov::Shape{1}, {0}),
                                ov::op::v0::Constant::create(ov::element::i64, ov::Shape{1}, {need}),
                                ov::op::v0::Constant::create(ov::element::i64, ov::Shape{1}, {1}),
                                ov::op::v0::Constant::create(ov::element::i64, ov::Shape{1},
                                                             {static_cast<int64_t>(a)}));
                            register_new_node(tail);
                            next = std::make_shared<ov::op::v0::Concat>(ov::OutputVector{in, tail->output(0)},
                                                                        static_cast<int64_t>(a));
                            cur = target;
                        }
                        in = next;
                        register_new_node(in.get_node_shared_ptr());
                    }
                }
                node->input(i).replace_source_output(in);
                changed = true;
            }
            return changed;
        }

        auto lhs = node->input_value(0);
        auto rhs = node->input_value(1);

        // A tensor-vs-Constant mismatch is the norm's own eps / 1-over-sqrt arithmetic. That
        // folds into the `rms` primitive itself instead of becoming a fused eltwise post-op,
        // so it is not affected and is left alone.
        if (ov::is_type<ov::op::v0::Constant>(lhs.get_node()) ||
            ov::is_type<ov::op::v0::Constant>(rhs.get_node())) {
            return false;
        }

        const auto lhs_rank = lhs.get_partial_shape().rank();
        const auto rhs_rank = rhs.get_partial_shape().rank();
        if (lhs_rank.is_dynamic() || rhs_rank.is_dynamic() || lhs_rank == rhs_rank) {
            return false;
        }

        const size_t shorter_idx = lhs_rank.get_length() < rhs_rank.get_length() ? 0 : 1;
        const auto & shorter = shorter_idx == 0 ? lhs : rhs;

        // The defect is with the norm output as the higher-rank operand. When the norm output is the
        // lower-rank one (gemma-3 adds it to a rank-4 residual), unsqueezing it puts the Unsqueeze between
        // `rms` and its post-op, and the GPU plugin then computes the layer wrongly.
        if (is_rms_norm_output(shorter)) {
            return false;
        }
        const int64_t diff = std::abs(lhs_rank.get_length() - rhs_rank.get_length());

        std::vector<int64_t> axes(static_cast<size_t>(diff));
        std::iota(axes.begin(), axes.end(), 0);
        auto unsqueeze = std::make_shared<ov::op::v0::Unsqueeze>(
            shorter, ov::op::v0::Constant::create(ov::element::i64, ov::Shape{ axes.size() }, axes));

        node->input(shorter_idx).replace_source_output(unsqueeze->output(0));
        register_new_node(unsqueeze);
        return true;
    };

    register_matcher(
        std::make_shared<ov::pass::pattern::Matcher>(eltwise_m, "ov::frontend::ggml::pass::AlignEltwiseOperandRanks"),
        callback);
}

}  // namespace pass
}  // namespace ggml
}  // namespace frontend
}  // namespace ov
