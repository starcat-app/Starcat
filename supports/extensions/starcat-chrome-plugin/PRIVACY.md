# Privacy Policy

Starcat Chrome Plugin is a local companion extension for Starcat. It enhances GitHub repository pages with context already available in the Starcat app.

## Data Collection

The extension does not collect, sell, or share personal data.

The extension does not:

- Track browsing history.
- Send page content to Starcat servers.
- Call GitHub APIs directly.
- Call OpenSSF, AI providers, or Starcat backend services directly.
- Use analytics, telemetry, or advertising SDKs.

## Local Data Storage

The extension stores only the minimum pairing configuration in `chrome.storage.local`:

- Starcat local service port.
- Companion bearer token.

The bearer token is used only to authenticate requests to the local Starcat app service on `127.0.0.1`.

## Local Communication

The extension communicates with:

```text
http://127.0.0.1:{port}/plugin/v1
```

The Starcat app owns all business data, including repository context, private notes, wiki links, recommendations, health scores, and CodeFlow / Codebase actions.

## GitHub Page Access

The extension reads the current GitHub page URL to identify the repository owner and name. It injects a Starcat panel into GitHub repository pages only.

## Private Notes

When you edit a note from GitHub, the extension sends the note content to the local Starcat app. The extension does not persist note content in Chrome storage.

## Changes

Privacy-related changes should be documented in this file before release.
