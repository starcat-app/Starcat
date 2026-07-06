# AGENTS.md

This directory contains Starcat browser extensions.

## Projects

- `starcat-chrome-plugin`: Chrome WebExtension.
- `starcat-safari-plugin`: Safari WebExtension.

## Tech Stack

- WebExtension Manifest V3.
- Plain JavaScript, HTML, and CSS.
- No build step is required for the extension source.
- Chrome uses the `chrome.*` extension APIs.
- Safari uses `globalThis.browser || globalThis.chrome` as the extension API compatibility layer.
- Both extensions talk to the Starcat macOS app through the local Companion API under `/plugin/v1/*`.
- Safari content scripts should call the local Companion API through `src/background/background.js`, because Safari applies stricter page-context CORS behavior to content scripts.

## Required Sync Rule

Chrome and Safari extension behavior must stay aligned. When changing a feature, manifest permission, content script, shared API helper, CSS surface, popup, or options page in one extension, check whether the same change is required in the other extension and apply it there too unless the task explicitly says the feature is single-browser only.
