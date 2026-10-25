# Testing and evidence boundaries

This source export is not a test receipt. Record the exact commit, baseline flag, command, host/OS, inputs and result. A source test or successful build is not a completed Perplexity task or an end-to-end acceptance.

## Clean remote snapshot —23October2026

The exact repository root `7fe8d2159e7299167b418e5d0e7e8b6d800a0e79` was cloned remotely into an empty checkout. All70manifest entries matched; the baseline command below passed99tests (79Core+20Mac), zero failures/skips. The baseline wrapper then built the app and passed deep/strict ad-hoc signature verification. BundleID `app.pip.hybrid.baseline`, version0.1.0, executableSHA256 `7bf8e6f2e326696e6ad41574bd40f52f7850eca22aeb319f0ad923cb2d33d8b6`. Tracked status remained clean. Host: macOS27.0.1(26A434), arm64.

These are source/package checks for that exact snapshot. Later documentation-only changes do not imply a new native acceptance. No Perplexity task parity, owner-Keychain, live-provider, accessibility or public-binary acceptance follows from them.

## Shared-source refresh candidate — 25 October 2026

The prepared candidate pins `Ghostzy0/pip-hybrid@b4a4198a4fb65394f5d857fe5bf99f1ed9ce59fb`. Its public export manifest SHA-256 is `d29dfc6beae174f8c7d298c5c0184ddabb5932bb12e3701414f3695a58ba71d2`. The generated replica records a path-identical, hash-bound shared subset of 47 files: 41 source/test files match internal source revision `14d6d7dc34382d6d4472b973bf2c1ca475f1a4fa` byte-for-byte, plus six package, licence, catalogue and build-support files. The shared-subset manifest SHA-256 is `4324283161b504b684ff3e884f06696d2f4938db48b994b36c2860c958cc7c16`. `scripts/build-mac-shared.sh` is verified separately as a byte-identical renamed copy of the pinned custom source's `scripts/build-mac.sh` (SHA-256 `fee9d930998c70c71d44a7c9c73704595c5d4d56441e36ca5bcb9f70a14ad41c`). It is not counted among the 47 path-identical files, but remains covered by the full replica export manifest. This is source provenance only; the neutral replica remains partial and does not inherit custom-edition acceptance.

The custom PR4 candidate `b4a4198a4fb65394f5d857fe5bf99f1ed9ce59fb` passed all four hosted native test/package jobs in run `40164944839` and manual source checks in run `40165019714`. Those checks qualify only the custom candidate. The replica export was prepared from public `main` at `41e341111d5ea90667bd64bb82963162651f337a`; independent source review, replica-specific baseline CI/package and native acceptance remain pending. Do not infer model inference, Keychain/provider, UI/accessibility, or complete Perplexity workflow acceptance from source hashes or another edition's tests.

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
