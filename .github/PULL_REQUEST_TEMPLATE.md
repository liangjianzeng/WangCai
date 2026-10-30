## What

<!-- One paragraph. What changed, and what problem does it solve? -->

Linked issue / roadmap item:

## Type

- [ ] correctness fix (graph construction / op lowering / cache contract)
- [ ] performance
- [ ] new env var / diagnostic
- [ ] build or tooling
- [ ] documentation (including a rejected hypothesis — those are welcome)

## Measurements

Required for anything that changes execution. Paste the actual output, not a summary.

| | before | after |
|---|---|---|
| prompt eval (t/s) | | |
| decode (t/s) | | |
| top-1 agreement vs CPU reference | | |
| cosine vs CPU reference (decode) | | |

Command line, `-c`, `-b`, `GGML_OPENVINO_PREFILL_CHUNK_SIZE`, prompt/generated token counts, cold or
warm compiled-graph cache:

```
```

## Verification

- [ ] `tools\run-npu.ps1 -Backend native` — CPU reference still coherent
- [ ] `tools\run-npu.ps1 -Backend static` — static path on CPU still coherent
- [ ] `tools\run-npu.ps1 -Backend npu` — NPU run recorded
- [ ] `tools\compare-tensors.ps1` output attached (for anything touching graph construction)
- [ ] passes aligned with `tools\top-token.ps1` before comparing
- [ ] a fresh `GGML_OPENVINO_CACHE_DIR` was used per configuration
- [ ] `AGENTS.md` / `CLAUDE.md` and other agent-memory files are not in the diff

## Notes for review

- If you changed an input shape, both sides of the static contract moved together
  (`get_graph_input_shape` **and** the static binder) — say which two places.
- If you added an env var, it is registered in the table in `ggml-openvino-extra.cpp` and documented
  in [docs/env-vars.md](../docs/env-vars.md).
- If you disabled something rather than fixing it, say so plainly and record it in
  [CHANGELOG.md](../CHANGELOG.md).
