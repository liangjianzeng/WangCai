# Security Policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub private vulnerability reporting](https://github.com/liangjianzeng/WangCai/security/advisories/new)
rather than a public issue. We aim to acknowledge within 7 days.

## What counts

- Anything that lets a malicious GGUF file, tokenizer vocabulary, chat template or generated token
  stream cause memory corruption, an out-of-bounds access, or code execution in the OpenVINO backend
  or the tools in this repository.
- Path traversal in the diagnostic dumps, cache handling, or anything that writes files based on
  model-supplied names.
- Unbounded memory allocation reachable from a model file or a request (the NPU host-memory budget is
  already tight; a crafted model that blows it up is a denial of service).

## What does not count

- Wrong or degraded model output. That is a correctness bug — open a normal issue with the artifacts
  from [CONTRIBUTING.md](CONTRIBUTING.md). It matters a lot to this project, but it is not a security
  advisory.
- Crashes in the OpenVINO NPU plugin itself (`ov::Exception`, `ZE_RESULT_*`). Report upstream to Intel,
  and open an issue here too so we can document a workaround.
- Prompt injection through model output. This project does not execute model output; if you wire it
  into something that does, treat generated text as untrusted input.

## Scope

WangCai is a patch set plus tooling on top of llama.cpp and OpenVINO. Vulnerabilities in those upstreams
belong to their maintainers; we will help route a report and ship a fix here if our patch set
contributes to it.

## Version support

Only the current `main` branch is supported. There are no released versions yet, so the pinned
llama.cpp and OpenVINO versions listed in [docs/status.md](docs/status.md) are the security-relevant
baseline for any report.
