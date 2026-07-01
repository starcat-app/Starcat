# Security Policy

## Supported Versions

Security fixes target the latest published version of Starcat Chrome Plugin.

## Security Boundary

Starcat Chrome Plugin is a browser extension that talks to the Starcat app through a local loopback HTTP API:

```text
http://127.0.0.1:{port}/plugin/v1
```

The extension must not:

- Expose the Companion bearer token in logs, page DOM, URLs, or remote requests.
- Send Starcat private notes to any remote service.
- Call GitHub, OpenSSF, AI providers, or Starcat backend services directly.
- Broaden host permissions beyond the minimum needed for GitHub pages and `127.0.0.1`.

## Reporting a Vulnerability

Please report security issues privately through the Starcat project maintainer channel before opening a public issue.

Include:

- Affected version or commit.
- Steps to reproduce.
- Expected and actual behavior.
- Any relevant browser, macOS, and Starcat app versions.

## Local Token Handling

The Companion bearer token authorizes only local loopback API access. Treat it as a secret:

- Do not publish it in screenshots, bug reports, or logs.
- Rotate it from the Starcat app if it may have leaked.
- Do not reuse GitHub tokens, AI keys, or Starcat backend API keys as the Companion token.
