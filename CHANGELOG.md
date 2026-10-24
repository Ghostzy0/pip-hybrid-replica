# Changes

## Shared reliability source update · 24 October 2026 · qualification pending

- Shared implementation now keeps ordinary quit available for retry or recovery when a final history save fails, instead of discarding the latest in-memory edit.
- Protected-history access policy checks failures and defaults to fail-closed behavior; this is source behavior, not proof that a native Keychain prompt cannot occur.
- The selected ChatGPT model is remembered and restored when still available; otherwise a listed Luna model is preferred before the first available fallback.

These source changes are carried into the neutral replica export from the independently reviewed custom source candidate, but the replica remains a partial, source-only implementation. The replica's own baseline CI/package/native evidence for this update is pending. No Perplexity workflow parity, provider lifecycle, owner-Keychain behavior, local-model inference, or public binary acceptance is implied. See [TESTING](docs/TESTING.md) for exact shared-source provenance and evidence boundaries.

## 0.1.0 · experimental baseline

- Publish a neutral/system-presentation baseline as an original, partial behavioral implementation for Mac local model chat and reviewed optional cloud requests.
- Record observed Perplexity controls separately from untested local and Hybrid task workflows.
- Keep the shared implementation provenance and source checks in [SHARED-CORE](docs/SHARED-CORE.md).

No completed Perplexity Hybrid task, complete parity, public binary, or production readiness is claimed.
