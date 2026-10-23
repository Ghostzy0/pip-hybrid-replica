# Data and network boundaries

This document describes code boundaries and intended use, not a security/privacy certification. Check the exact source and runtime on your host before using sensitive material.

## Local use

Local-only chat uses a separately retrieved llama.cpp runtime and the model you select. Build preparation may contact GitHub for the pinned runtime; choosing a model contacts its pinned publisher. The build does not bundle or download model weights. Offline inference must be qualified for the chosen host and model.

The child runtime uses legacy `/usr/bin/sandbox-exec` rules to deny non-loopback networking while permitting loopback requests. The profile otherwise allows file access by default; this is not a full filesystem sandbox, an App Sandbox entitlement, or proof of network isolation on every macOS release. Native platform/network checks remain separate.

The app accepts selected small UTF-8 text input, not an unrestricted document crawler. Hardware fit is an estimate; memory/context/runtime needs vary.

## Optional provider use

Optional ChatGPT requests require their own supported sign-in and consent. Review the exact outgoing conversation before sending. A connected account does not promise access to every model or grant API billing. Local-only requests do not silently fall back to a cloud/API route. Provider capabilities and terms can change; verify eligibility at use time.

Sensitive-information detection is advisory and can miss data. Review the payload yourself. Provider sign-in and requests use network services.

## Saved history and credentials

Saved chat content uses AES-256-GCM with a separate key in the legacy Mac login Keychain. Losing the key can make history unrecoverable; macOS may show a native approval prompt. Do not bypass prompts or repeat them in the background. Locked/unavailable history should remain clearly reported.

This baseline retains the `Pip Hybrid Baseline` preferences/data/Keychain namespace. It does not automatically adopt LocalSwitch or another edition's data. Namespace separation is not an OS sandbox.

## Safe reports

Use synthetic content for initial runs, screenshots and bug reports. Never publish tokens, private histories, model caches, or account-bearing screenshots. Source tests cannot establish live retention/deletion, provider lifecycle or protected-storage behavior on your Mac. See [testing](TESTING.md) and [security reporting](../SECURITY.md).
