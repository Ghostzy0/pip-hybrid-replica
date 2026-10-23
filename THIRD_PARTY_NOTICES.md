# Third-party notices and reference boundary

The source retains the upstream LocalSwitch MIT licence and copyright in [LICENSE](LICENSE). Subsequent application code is original MIT-licensed project work. No Perplexity source code, marks, screenshots, model files, or proprietary app resources are included. Perplexity is a workflow reference only; this project is not affiliated with or endorsed by Perplexity.

## Runtime

The build preparation script retrieves the pinned llama.cpp `b11768` macOS arm64 archive from its upstream release. Pinned commit: `1ba568c5ad5c6c718984bd2bf4e7c71485b706f9`. Archive SHA-256: `15afe10cd251b3c22926fae17348bc2bd85dd2cba9ed39a97659983d01b9f979`. The preserved [MIT notice](apps/mac/Resources/Licenses/llama.cpp-MIT.txt) travels with the app. Runtime binaries and caches are excluded from source. Check the exact upstream component notices before redistributing a packaged runtime.

## Models

No model weights are included. Catalogue URLs are pinned to publisher revisions and downloads are checked against expected SHA-256 values in [Catalogue.swift](apps/mac/Sources/LocalSwitchCore/Catalogue.swift). The listed Qwen catalogue entries use Apache-2.0; the [licence](apps/mac/Resources/Licenses/Qwen-Apache-2.0.txt) is preserved. A runtime licence does not grant rights to arbitrary models. Check the selected model's terms before use or redistribution.

## References

The [Perplexity Hybrid Compute page](https://www.perplexity.ai/hub/products/hybrid-compute) informed workflow research. We do not redistribute its source, branding, screenshots, or app resources. Public product descriptions, static package observations, and the handful of controls exercised in the signed Mac app are separate evidence types; see [parity and limits](docs/PARITY.md).
