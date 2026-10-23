# Testing and evidence boundaries

This source export is not a test receipt. Record the exact commit, baseline flag, command, host/OS, inputs and result. A source test or successful build is not a completed Perplexity task or an end-to-end acceptance.

## Clean remote snapshot —23October2026

The exact repository root `7fe8d2159e7299167b418e5d0e7e8b6d800a0e79` was cloned remotely into an empty checkout. All70manifest entries matched; the baseline command below passed99tests (79Core+20Mac), zero failures/skips. The baseline wrapper then built the app and passed deep/strict ad-hoc signature verification. BundleID `app.pip.hybrid.baseline`, version0.1.0, executableSHA256 `7bf8e6f2e326696e6ad41574bd40f52f7850eca22aeb319f0ad923cb2d33d8b6`. Tracked status remained clean. Host: macOS27.0.1(26A434), arm64.

These are source/package checks for that exact snapshot. Later documentation-only changes do not imply a new native acceptance. No Perplexity task parity, owner-Keychain, live-provider, accessibility or public-binary acceptance follows from them.

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
