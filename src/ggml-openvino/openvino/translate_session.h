#pragma once

#include "input_model.h"
#include "node_context.h"

#include <map>

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

private:
    std::shared_ptr<Model> apply_transformations(std::shared_ptr<Model> model);
    const frontend::InputModel::Ptr m_input_model;
    const std::unordered_map<std::string, CreatorFunction> & m_translator_map;
    std::shared_ptr<Model> m_ov_model;
    bool m_naive;
    std::map<ScatterIdxKey, Output<Node>> m_shared_scatter_idx_chain;
};

}  // namespace ggml
}  // namespace frontend
}  // namespace ov
