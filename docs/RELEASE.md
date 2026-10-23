# Release and installation limits

This snapshot is experimental source. It does not claim a public release binary, signed installer, notarisation, automatic update channel or production readiness. Verify the repository and release state you are viewing; this source export does not itself prove publication.

The local package command is:

```sh
./scripts/build-mac.sh baseline
```

The script may fetch only the pinned runtime and leaves the app closed. Output under `dist/` is a local ad-hoc signed app, not a notarised installer. macOS account/permission prompts require the owner's action. Do not disable Gatekeeper or system protections globally.

Before offering a binary, build and test the exact source from a clean checkout; review independent functional/data, interface/accessibility, package/security/licence findings; verify notices and model terms; record real version, source, tested hosts and unresolved gaps; inspect exact artefacts and checksums; and publish only what those checks support. A source manifest is not a signature, SBOM, runtime acceptance, or release receipt. Never publish credentials, personal data, model weights, private captures or generated runtime caches as release assets.
