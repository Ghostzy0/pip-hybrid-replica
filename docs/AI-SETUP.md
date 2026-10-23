# Setup with a coding assistant

From the checked-out repository, give an assistant this prompt:

> Read README.md, docs/EDITIONS.md, docs/PRIVACY.md, docs/PARITY.md and docs/TESTING.md. Confirm this is the intended Ghostzy0/pip-hybrid-replica source and check the documented Apple Silicon/Xcode requirements. Run only the neutral baseline test and local build commands from docs/EDITIONS.md. Report the exact source commit, host, results and output path, then leave the app closed. Do not download model weights, connect accounts, read personal stores, change OS permissions or claim full Perplexity parity.

Check these prerequisites without changing the system:

```sh
uname -m
sw_vers
xcode-select -p
xcrun swift --version
python3 --version
```

From the repository root, run the two baseline commands in [EDITIONS](EDITIONS.md). The packaging script can retrieve its pinned runtime when absent. It does not download model weights or open the app. Missing full Xcode selection or a native macOS approval requires the owner's action; do not use `sudo`, change the selected toolchain, purchase a developer account, or weaken system protections automatically.

Record the exact commit, edition, OS/architecture, command results and package path. A compile does not verify local inference, protected history, provider access, accessibility, or the reference workflows.
