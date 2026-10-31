#include "align_eltwise_ranks.h"

#include <numeric>
#include <openvino/op/add.hpp>
#include <openvino/op/concat.hpp>
#include <openvino/op/constant.hpp>
#include <openvino/op/divide.hpp>
#include <openvino/op/multiply.hpp>
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

}  // namespace

AlignEltwiseOperandRanks::AlignEltwiseOperandRanks() {
    auto eltwise_m = ov::pass::pattern::wrap_type<ov::op::v1::Add, ov::op::v1::Multiply, ov::op::v1::Subtract>();

    const auto callback = [this](ov::pass::pattern::Matcher & m) {
        auto node = m.get_match_root();
        if (node->get_input_size() != 2) {
            return false;
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

        // NPUW broadcast-tile defect: for the 1-token decode shape [..., 4, X], an operand
        // implicitly broadcast along the 4-head axis comes back with the odd heads garbled
        // (the k_norm weight multiply: heads 0/2 bit-exact, heads 1/3 destroyed -- the whole
        // answer-quality defect). Tile the broadcast operand explicitly with Concat so no
        // implicit head-axis broadcast reaches the device. Semantically neutral everywhere
        // (the prefill's [1,256,4,128] gets the same treatment and its outputs are unchanged).
        {
            const auto out_pshape = node->get_output_partial_shape(0);
            if (out_pshape.rank().is_static() && out_pshape.rank().get_length() >= 2) {
                const size_t head_axis = out_pshape.rank().get_length() - 2;
                const auto & head_dim = out_pshape[head_axis];
                if (head_dim.is_static() && head_dim.get_length() == 4) {
                    for (size_t i = 0; i < 2; ++i) {
                        const auto in_shape0 = node->input_value(i).get_partial_shape();
                        if (!(in_shape0.rank().is_static() && in_shape0.rank().get_length() <= out_pshape.rank().get_length())) {
                            continue;
                        }
                        ov::Output<ov::Node> in = node->input_value(i);
                        const int64_t rank_diff = static_cast<int64_t>(out_pshape.rank().get_length()) -
                                                  static_cast<int64_t>(in_shape0.rank().get_length());
                        if (rank_diff > 0) {
                            std::vector<int64_t> axes(static_cast<size_t>(rank_diff));
                            std::iota(axes.begin(), axes.end(), 0);
                            in = std::make_shared<ov::op::v0::Unsqueeze>(
                                in, ov::op::v0::Constant::create(ov::element::i64, ov::Shape{axes.size()}, axes));
                        }
                        const auto in_shape = in.get_partial_shape();
                        if (in_shape.rank().is_static() && in_shape[head_axis].is_static() &&
                            in_shape[head_axis].get_length() == 1) {
                            auto tiled = std::make_shared<ov::op::v0::Concat>(
                                ov::OutputVector{in, in, in, in}, static_cast<int64_t>(head_axis));
                            node->input(i).replace_source_output(tiled->output(0));
                            register_new_node(tiled);
                        }
                    }
                }
            }
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
