# Testing and evidence boundaries

This source export is not a test receipt. Record the exact commit, baseline flag, command, host/OS, inputs and result. A source test or successful build is not a completed Perplexity task or an end-to-end acceptance.

## Clean remote snapshot —23October2026

The exact repository root `7fe8d2159e7299167b418e5d0e7e8b6d800a0e79` was cloned remotely into an empty checkout. All70manifest entries matched; the baseline command below passed99tests (79Core+20Mac), zero failures/skips. The baseline wrapper then built the app and passed deep/strict ad-hoc signature verification. BundleID `app.pip.hybrid.baseline`, version0.1.0, executableSHA256 `7bf8e6f2e326696e6ad41574bd40f52f7850eca22aeb319f0ad923cb2d33d8b6`. Tracked status remained clean. Host: macOS27.0.1(26A434), arm64.

These are source/package checks for that exact snapshot. Later documentation-only changes do not imply a new native acceptance. No Perplexity task parity, owner-Keychain, live-provider, accessibility or public-binary acceptance follows from them.

## Shared-source refresh candidate — 24 October 2026

The exporter pins the independently reviewed public custom-source candidate `Ghostzy0/pip-hybrid@c1c2e226a841d9767dd837a21e1975ecfed35fbc`. Its export manifest contains 77 files (manifest SHA-256 `9f048946608d3693f6ec08ad5f69775d894bca7adc99fa7b3ef935a4dfa48ac5`). The generated replica records a path-identical, hash-bound shared subset of 47 files: 41 source/test files match the corresponding internal `84cdf43` snapshot byte-for-byte, plus six package, licence, catalogue and build-support files. Its shared-subset manifest SHA-256 is `d1c95d777c7b60a89091a18e8b9cae5268fff1d5855bf04d2e9e81f840c4ce82`. The former 48th entry, `scripts/build-mac-shared.sh`, is verified separately as a byte-identical renamed copy of the pinned custom source's `scripts/build-mac.sh` (SHA-256 `fee9d930998c70c71d44a7c9c73704595c5d4d56441e36ca5bcb9f70a14ad41c`); it remains covered by the full replica export manifest. The neutral replica remains partial and does not inherit custom-edition acceptance.

A separate local run on the custom Pip Plus candidate recorded 109 passing tests (84 Core, 25 Mac) and built an ad-hoc local package and the current Smoke executable. The merged custom-source candidate passed hosted tests and package workflows for all four variants (109 tests each), runs `40119565332` and `40119671624`. These results are limited to those custom-source inputs and do not qualify the replica. On the prepared replica candidate based on `main` at `dc39561e7ecb996968097ac8bafff080bedcc2b0`, its independent review, baseline CI, package and native evidence are still pending. Do not infer model inference, Keychain/provider, UI/accessibility, or complete Perplexity workflow acceptance from source hashes or another edition's tests.

## Reproducible neutral checks

On an Apple Silicon Mac with full Xcode selected:

```sh
sh -n scripts/build-mac.sh
sh -n scripts/build-mac-shared.sh
python3 -m py_compile scripts/prepare-mac-runtime.py
swift test --package-path apps/mac --scratch-path apps/mac/.build-baseline --jobs 4 -Xswiftc -DBASELINE_EDITION
swift build --package-path apps/mac --scratch-path apps/mac/.build-baseline --jobs 4 -c release -Xswiftc -DBASELINE_EDITION --product LocalSwitch
./scripts/build-mac.sh baseline
```

The build script downloads/verifies the pinned runtime if missing and ad-hoc signs the local package. It does not fetch model weights or launch the app. Do not run simultaneous heavy builds on a memory-constrained host.

## Remaining runtime gates

| Area | Needed evidence | Current claim |
| --- | --- | --- |
| Reference workflows | Search, Computer, model setup, Local and complete Hybrid task on the named version | Controls partly observed; completed local/Hybrid outcomes unavailable |
| Exact replica package | Clean checkout, baseline identity/resources, signature and output receipt | Not provided by this document |
| Local inference | Chosen model/hash, synthetic prompt, streamed output, Stop, resource use and restart | Host/model-specific; not inferred from fixtures |
| Protected history | Native approval, encrypted restart and unavailable-key recovery without data loss | Requires consented native observation |
| Provider | Authorized supported sign-in, exact payload review/send/cancel/error and persistence | Requires separate consent and account evidence |
| Accessibility and visual parity | Equivalent native states, keyboard/focus, assistive tech, reduced motion and comparison | No blanket conformance or 1:1 claim |
| Public scope/licences | Reviewed allowlist, source pin, notices, weights/secret exclusion | Export checks do not prove runtime acceptance |

Use synthetic content. Never alter owner stores or revoke working credentials to test. Keep private captures outside the repository. Do not publish a result without reviewing its exact content.
