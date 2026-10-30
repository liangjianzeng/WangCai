---
name: Bug report
about: Something fails to build, compile, or produce sane output
title: "[bug] "
labels: bug
assignees: ''
---

<!--
Read https://github.com/liangjianzeng/WangCai/blob/main/CONTRIBUTING.md#before-you-open-an-issue first.
The single most useful thing you can attach is the compare-tensors.ps1 output for a wrong-output bug,
and the full log for a compile failure. Most reports resolve to one of: graph did not compile /
ran but numbers are wrong / ran on the wrong device - and the console alone cannot tell them apart.
-->

## Which kind of failure

- [ ] build fails (CMake / MSVC)
- [ ] graph compilation fails (`ov::Exception`, `Check ... failed`)
- [ ] runs, output is wrong (no exception)
- [ ] runs, but not on the device I asked for
- [ ] performance, not correctness

## Environment

| | |
|---|---|
| OS build | |
| CPU / SoC | |
| NPU driver version | |
| OpenVINO version | |
| llama.cpp commit | |
| WangCai commit | |
| patch applied cleanly? | yes / no (rebased) |
| model file, size, quantization | |

## Command

```powershell
# exact command line, including -c / -b / -n / -fa / -np and every GGML_OPENVINO_* variable
```

## Output

```
full log, not an excerpt
```

## Expected vs actual

## Artifacts

- [ ] `llama-cli --list-devices` output
- [ ] run log with `GGML_OPENVINO_CACHE_DIR` set to a fresh directory
- [ ] for wrong output: `GGML_OPENVINO_DUMP_BIN` captures from both the NPU and `-Backend static`,
      plus `tools\compare-tensors.ps1` output
- [ ] `tools\top-token.ps1 -Dir <each dump dir>` (so passes can be aligned)

## Things already tried

<!-- Especially: fresh cache dir per configuration? chat template (`-st`) rather than raw completion?
     `-fa 1`? `-np 1`? Verified the file size of the GGUF against the source? -->
