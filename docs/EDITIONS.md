# Neutral baseline

This repository exports one app variant: **Pip Hybrid Baseline**, the native/system presentation at feature level 0.1. “Neutral” describes its system appearance; the existing app identity and storage namespace are retained. This repository's wrapper refuses Pip and enhanced edition arguments.

## Reproduce

On an Apple Silicon Mac with macOS 14 or later, full Xcode selected and Python 3:

```sh
swift test --package-path apps/mac --scratch-path apps/mac/.build-baseline --jobs 4 -Xswiftc -DBASELINE_EDITION
./scripts/build-mac.sh baseline
```

The baseline uses `BASELINE_EDITION`; the wrapper calls the preserved `build-mac-shared.sh baseline` implementation. The bundle identity is `app.pip.hybrid.baseline` and the display name is `Pip Hybrid Baseline`. Its model/history and Keychain services follow that identity. No automatic migration or import occurs from LocalSwitch or another edition.

The build may retrieve the pinned llama.cpp runtime. It does not fetch model weights, connect an account, launch the app, or change OS permissions. The app package is ad-hoc signed locally. See [testing](TESTING.md) for what these commands do and do not establish.
