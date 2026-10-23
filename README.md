# Perplexity Hybrid Compute for Mac: an original workflow experiment

An experimental native Mac app exploring local model chat, optional reviewed cloud requests and selected elements of the Perplexity Hybrid Compute workflow. This repository publishes **one neutral baseline** under the existing app identity, Pip Hybrid Baseline.

This is an independently authored, partial behavioral recreation. It is **not** a faithful 1:1 recreation, a Perplexity client, or affiliated with or endorsed by Perplexity. We use Perplexity as a workflow reference and keep its code, marks, screenshots and proprietary resources out of this project. See [the observed parity and gaps](docs/PARITY.md).

## What the baseline does

- Runs local chat with a separately retrieved, SHA-256-verified llama.cpp runtime and a model you choose from the pinned catalogue.
- Shows a hardware-aware model fit estimate, verified model downloads, visible Stop, and encrypted saved chat history.
- Offers an optional ChatGPT request path with explicit review of the outgoing conversation.
- Provides a native Mac workspace and local setup flow.

It does not yet implement Perplexity's Search and Computer modes, complete Hybrid local→cloud→local orchestration, broad web research, Perplexity account integration, or its model catalogue. A framework name or previously observed control is not proof that these behaviors have been reproduced. See [parity](docs/PARITY.md) and [test limits](docs/TESTING.md).

## Build the neutral baseline

Requires an Apple Silicon Mac, macOS 14 or later, full Xcode with its command-line tools selected, Python 3 and enough free disk/memory for the runtime and selected model. These are declared requirements; they do not mean every compatible Mac has been tested.

```sh
swift test --package-path apps/mac --scratch-path apps/mac/.build-baseline --jobs 4 -Xswiftc -DBASELINE_EDITION
./scripts/build-mac.sh baseline
```

The wrapper accepts `baseline` only. It invokes the preserved shared build implementation with the baseline argument. The build may retrieve the pinned llama.cpp runtime; it does not download model weights, sign into an account, launch the app, or change macOS permissions. The output is a local ad-hoc signed app, not a notarised installer. Follow [setup](docs/AI-SETUP.md) and [release limits](docs/RELEASE.md).

## Privacy and licences

Review [the documented data and network boundaries](docs/PRIVACY.md) before use. Use synthetic content first. Local model weights are separate downloads; no weights are bundled. The app does not silently switch local requests to a cloud or paid API route. The LocalSwitch MIT notice and third-party notices are preserved.

See [third-party notices](THIRD_PARTY_NOTICES.md), [testing](docs/TESTING.md), and [FAQ](docs/FAQ.md). Source, fixture tests, screenshots, and an ad-hoc build each provide limited evidence; none alone establishes full workflow, provider, security, accessibility, or release acceptance.
