# Perplexity Hybrid Compute parity and evidence limits

This project is an original, partial behavioral implementation informed by Perplexity for Mac 26.42.0 (145). It is not a faithful 1:1 recreation, official client, or affiliated project. No Perplexity code, branding, screenshots, or proprietary app resources are included.

## What was observed

In the signed-in reference app, the operator exercised Search and Computer composer modes; Standard with Hybrid and Local choices; first-use Hybrid setup; memory-aware model choices; preparation/cancellation with choice restoration; and project/history navigation. On the 32 GB Mac, the chooser showed PPLX Pro 27B, Qwen3.6 35B-A3B and Gemma 4 E4B with their sizes and a recommendation. A full local inference and completed Hybrid task were not observed.

Static inspection of the same version's package found separately named Hybrid onboarding, local inference and subagent frameworks, plus local endpoint declarations. Those names and declarations do not prove a request path, task routing, model identity or runtime behavior. The product page describes cloud/local task splitting and privacy review; marketing text is not runtime evidence.

## Current neutral baseline

The app implements local model setup/downloads, local chat and Stop, encrypted history, native workspace views, hardware fit estimates, and an optional explicitly reviewed ChatGPT request path. It uses independently authored code on a licensed LocalSwitch foundation and the separately licensed llama.cpp runtime/model catalogue. It does not reproduce Perplexity source or assets.

The baseline does **not** establish Perplexity Search or Computer modes, its Standard/Hybrid/Local selector, complete local→cloud→local task orchestration, broad web research, Perplexity model selection/download identity, its exact layout or interaction timing, or its privacy classifier behavior. The presence of a cloud review surface is not a Hybrid task graph.

## Minimum acceptance before a full recreation claim

1. Capture the same-version reference screens and state transitions for setup, Search, Computer, Standard/Hybrid/Local, model download/cancel/retry, task progress/review/result, history, settings and failure states, in light and dark.
2. Complete lawful reference local and Hybrid tasks. Record model/provider/artifact identity, output, review boundaries, Stop, errors, restart and memory/resource behavior.
3. Run those same scenarios against the exact current native release build; preserve inputs/results and distinguish pass, partial, fail and unavailable states.
4. Test denial, offline/low-memory, cancellation, task restart, history recovery and provider consent/data boundaries with synthetic content and owner-authorized accounts only.
5. Compare native layout, keyboard/focus, assistive technology and reduced-motion behavior at equivalent window/display conditions; document unresolved differences.

Until those gates are met, describe only the implemented baseline workflows and the specifically observed reference controls. A static package inventory, source test, simulated browser concept, screenshot or successful compile cannot close these gaps.
