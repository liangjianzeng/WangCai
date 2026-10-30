# Documentation

Read in this order if you are new to the project; jump straight to the last two if you are here to
debug something.

| # | Document | One-line answer to |
|---|---|---|
| 1 | [getting-started.md](getting-started.md) | "how do I get one NPU run on screen" |
| 2 | [build.md](build.md) | "why does the build want a GPU header I do not have" |
| 3 | [architecture.md](architecture.md) | "what runs where, and what a static graph costs you" |
| 4 | [env-vars.md](env-vars.md) | "what can I turn without rebuilding" |
| 5 | [benchmarks.md](benchmarks.md) | "how fast is it, and what do those numbers not prove" |
| 6 | [status.md](status.md) | "what actually works today, with the command that proves it" |
| 7 | [npu-internals.md](npu-internals.md) | "what is hard about the NPU, and what did we already rule out" |
| 8 | [troubleshooting.md](troubleshooting.md) | "what does this error mean" |
| 9 | [roadmap.md](roadmap.md) | "what is worth working on" |

Two more entry points outside this directory:

- [../patches/README.md](../patches/README.md) — every hunk we apply to llama.cpp and why it is needed.
- [../tools/README.md](../tools/README.md) — the scripts you will actually run.

## The three facts worth knowing before reading anything else

1. **The NPU executes static graphs.** Every variable dimension has to be decided at compile time, and
   the shape baked into the compiled parameter must match the tensor the host binds — two code paths
   that must never drift apart.
2. **`GGML_OPENVINO_FORCE_STATIC=1` on the CPU runs that same code path**, without the 36-second NPU
   compile. It is the reason this project is tractable: translation bugs reproduce on CPU, plugin bugs
   do not.
3. **Aggregate statistics lie.** `min/max/mean` per output hides a single wrong row, and a wrong row is
   the most common failure here. Compare tensors element-wise and align passes by top-1 token id first.

## Contributing docs

Documentation is where most of the value of this repository lives: the patch set is 213 lines, the
measurements and the rejected hypotheses are what save the next person a week. If you disprove
something, write it down — [../CHANGELOG.md](../CHANGELOG.md) has a section for exactly that.

Keep claims falsifiable: a number without the command line that produced it is an anecdote.
