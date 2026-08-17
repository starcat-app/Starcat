# Security Policy

## Reporting a vulnerability

Report suspected vulnerabilities through
[GitHub Security Advisories](https://github.com/starcat-app/Starcat/security/advisories/new).
Do not publish credentials, tokens, exploit details, private repositories, customer data,
or Starcat private data in a public issue or pull request.

Include the affected version or commit, macOS version, distribution channel (Mac App Store
or Direct), reproduction steps, and expected impact. You should receive an acknowledgement
within seven days.

## Supported versions

Security fixes are provided for the latest published stable Mac App Store and Direct
releases.

## Security boundaries

Starcat is a local-first macOS app. The following boundaries apply to official builds and
to this source tree:

- GitHub OAuth tokens, GitHub App user tokens, AI provider keys, and Direct license
  material belong in Keychain or the local gitignored `Configs/Secrets.xcconfig`. Never
  commit those files, Sparkle private keys, `.p8` / `.p12` certificates, or `.env` files.
- GitHub OAuth Client ID and GitHub App Client ID are public identifiers. Client secrets
  and GitHub App private keys are not. Contributors must create their own OAuth App / GitHub
  App for local development instead of embedding production secrets.
- User data (tags, notes, reading status, knowledge-base content) is stored in the local
  SQLite database. CloudKit syncs user data only. The GitHub repository cache can be rebuilt
  and is not a secret store.
- Direct updates are signed with Developer ID and notarized; Sparkle uses an EdDSA public
  key in the app bundle. The matching private key must never enter Git.
- Aptabase telemetry is opt-in and must not include tokens or private repository content.
- AI features send repository context only after the user enables them; AI suggestions are
  not written until the user confirms.

A compromised GitHub account, a compromised Apple ID / Developer certificate, local malware,
and a compromised Keychain are outside Starcat's protection boundary.
