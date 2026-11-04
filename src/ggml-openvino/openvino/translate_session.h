#pragma once

#include "input_model.h"
#include "node_context.h"

#include <map>
#include <utility>

namespace ov {
namespace frontend {
namespace ggml {

class TranslateSession {
public:
    TranslateSession(const frontend::InputModel::Ptr & input_model,
                     const std::unordered_map<std::string, CreatorFunction> & translator_map,
                     bool naive = false);

    std::shared_ptr<Model> get_converted_model();
    std::shared_ptr<Model> translate_graph(const frontend::InputModel::Ptr & input_model);

    // Per-graph memo for identical small node chains (P14, 2026-11-04): every K/V scatter in a
    // static graph rebuilt the same ScatterND index chain (Squeeze/Convert/ShapeOf/Broadcast/
    // Concat/Mod) from the same merged index parameter -- 2*n_layer copies that NPUW schedules
    // per instance (4B decode: 72 scatters ~= 570 small nodes, ~half the graph). The chain
    // depends only on the indices output and the destination row count, so one instance per
    // (indices node, dst_rows, mod-applied) is shared. Scoped to this session == one graph.
    struct ScatterIdxKey {
        const void * indices_node;
        int64_t dst_rows;
        bool mod_applied;
        bool operator<(const ScatterIdxKey & o) const {
            return indices_node != o.indices_node ? indices_node < o.indices_node :
                   dst_rows != o.dst_rows ? dst_rows < o.dst_rows : mod_applied < o.mod_applied;
        }
    };
    std::map<ScatterIdxKey, Output<Node>> & shared_scatter_idx_chain() { return m_shared_scatter_idx_chain; }

    // P14b (2026-11-04): same memo pattern for the rope cos/sin table-side chains. Every rope
    // node rebuilt its copy of the table lowering (NEOX-family: optional Reshape + duplication
    // Concats + the static-decode head-axis tile; NORMAL: the Unsqueeze/Broadcast/Reshape
    // expand) -- ~4-6 small nodes per rope node, 2*n_layer rope nodes per graph (1.7B prefill
    // profiled Multiply n=196 rope family 27%; 4B decode Add-38% carries the rope-2 family).
    // The table-side chain is fully determined by (cos/sin table node, half, head-tile width,
    // lowering kind); the tables themselves are already shared (put_shared cache_key or one
    // explicit graph input), so one pair per key covers the whole graph. Session == one graph.
    struct RopeCSKey {
        const void * table_node;
        int64_t half;
        int64_t tile_heads;  // 0 = no head-axis tile applied
        bool normal_expand;  // TYPE_NORMAL expand vs NEOX-family duplication
        bool f16_domain;     // P14d: tables converted to f16 (GGML_OPENVINO_ROPE_F16)
        bool operator<(const RopeCSKey & o) const {
            return table_node != o.table_node ? table_node < o.table_node :
                   half != o.half ? half < o.half :
                   tile_heads != o.tile_heads ? tile_heads < o.tile_heads :
                   normal_expand != o.normal_expand ? normal_expand < o.normal_expand :
                   f16_domain < o.f16_domain;
        }
    };
    std::map<RopeCSKey, std::pair<Output<Node>, Output<Node>>> & shared_rope_cos_sin() { return m_shared_rope_cos_sin; }

private:
    std::shared_ptr<Model> apply_transformations(std::shared_ptr<Model> model);
    const frontend::InputModel::Ptr m_input_model;
    const std::unordered_map<std::string, CreatorFunction> & m_translator_map;
    std::shared_ptr<Model> m_ov_model;
    bool m_naive;
    std::map<ScatterIdxKey, Output<Node>> m_shared_scatter_idx_chain;
    std::map<RopeCSKey, std::pair<Output<Node>, Output<Node>>> m_shared_rope_cos_sin;
};

}  // namespace ggml
}  // namespace frontend
}  // namespace ov
