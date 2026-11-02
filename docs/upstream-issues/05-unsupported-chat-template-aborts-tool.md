# Unsupported chat template aborts llama-completion with 0xC0000409 (two unguarded render paths)

## Summary

`llama-completion` aborts with 0xC0000409 (uncaught exception → `std::terminate`) **before a single
token is computed** for models whose chat template is not covered by the built-in template matcher —
observed with iFlytek Spark-X2.6-4B (works with 1.7B LFM3, whose template is covered). The exception
is `this custom template is not supported, try using --jinja`, raised by the non-jinja path of
`common_chat_templates_apply` and escaping **two** unguarded call sites in the tool:

1. `common_chat_format_example(...)` at startup (cosmetic "chat template example" print) —
   `common/chat.cpp` calls `common_chat_templates_apply` with no try/catch.
2. The real prompt's `common_chat_templates_apply(...)` in the conversation-mode branch of
   `tools/completion/completion.cpp` (plus `common_chat_format_single` inside
   `common/chat.cpp`, same pattern).

Symptom that hides the cause: the crash lands in `ucrtbase.dll` (fastfail) and — because backend
graph compilation happens in between — looks like an inference-stack fault. Debugging notes that
may save someone time: an ASAN build reports nothing (nothing is corrupted — it is a terminate),
and Windows Event Log shows the same ucrtbase offset for both binaries.

## Reproduce

```
llama-completion.exe -m Spark-X2.6-4B-Q4_K_M.gguf -p "Hello" -c 512 -n 8 -dev OPENVINO3
# 0xC0000409 right after "chat template is available, enabling conversation mode"

llama-completion.exe -m Spark-X2.6-4B-Q4_K_M.gguf -p "Hello" -c 512 -n 8 --jinja   # OK
llama-completion.exe -m Spark-X2.6-4B-Q4_K_M.gguf -p "Hello" -c 512 -n 8 -no-cnv   # OK
```

## Suggested fixes

- `common_chat_format_example`: wrap the render in try/catch and return an empty example — it is a
  cosmetic print and must not be fatal.
- The conversation-mode prompt construction: either catch and abort with a clear message
  ("unsupported chat template, pass --jinja"), or fall back to the jinja path automatically. A
  terminate with no message is the worst of the three.
- More generally: an unsupported template is a *config* problem, but terminating a process from a
  cosmetic code path turns it into a mysterious crash.

## Environment

Windows 11, llama.cpp @ abb76ab (WangCai fork), MSVC 2022, iFlytek Spark-X2.6-4B GGUF.
