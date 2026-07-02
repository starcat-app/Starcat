# Starcat Changelog

> All notable changes to Starcat. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
> Starcat follows [Semantic Versioning](https://semver.org/).

---

## v1.0.0

### Account & Sync

- **GitHub OAuth Login** — Device Flow authentication, token stored in Apple Keychain (Secure Enclave encryption), `read:user` + `public_repo` scopes.
- **Full + Incremental Stars Sync** — Paginated fetch with progress callback; incremental sync skips unchanged pages via `starred_at` cutoff; ETag cache reduces redundant requests.
- **Rate Limit Management** — Parses `X-RateLimit-*` headers, proactive backoff on limit with countdown UI.

### Main Interface (macOS Three-Column Layout)

- **NavigationSplitView** — Sidebar + repo list + detail panes, window frame persistence.
- **Sidebar** — User card (avatar / username / stats / profile entry), collapsible Tags & Languages groups with counts.
- **Contribution Graph + Snake Animation** — GitHub-style 53-week heatmap, 7 selectable snake game modes.
- **User Share Cards** — 5 themes (minimal B&W / thermal orange / GitHub green / white ID card / dark ID card), export as hi-res PNG or share to X, dynamic Metal flow background.

### Repository List

- **All Repos / Untagged / Languages / Tags** — Multi-dimension browsing; list caching + skeleton screens to avoid blank states on category switch.
- **Compact / Card Density** — Two density modes, persisted in Settings.
- **8 Sort Options** — By name / stars / last updated, etc.
- **FTS5 Full-Text Search** — Indexes repo name / description / owner / notes, BM25 ranking, CJK trigram tokenizer.
- **Structured Filtering** — Combine language / tag / status / archived / fork filters, save complex query presets.

### Repository Detail

- **Metadata Card** — Name / description / language / stars / forks / created / updated / topics / license.
- **README WebView Rendering** — WKWebView with local cache + ETag + SWR strategy, no repeated requests on 404.
- **GitHub Shortcuts** — Issues / Pull Requests / Releases / Homepage links open in default browser.
- **HTTPS / SSH Clone URL Copy** — One-click clipboard copy + toast feedback.
- **Unstar** — Detail page action + confirmation alert + GitHub API sync.

### Organization

- **Tag CRUD** — Create / edit / delete / merge tags, 12 preset colors (Apple HIG) + 30 SF Symbol icons + custom ColorPicker.
- **Batch Tagging** — Multi-select mode + floating bottom action bar.
- **Private Notes** — Per-repo Markdown notes, 800ms debounced auto-save, save status indicator.
- **Status Management** — Unread / Reading / Using / Archived, SF Symbol picker with instant persistence.

### Data Management

- **Local SQLite Cache** — GRDB 7 + DatabasePool, 10 tables + FTS5 + 4 triggers.
- **Cache Cleanup** — README + images (Kingfisher) + diagnostic logs, one-click from Settings.
- **Starred Export** — Single-file HTML / Markdown export; HTML version includes search / sort / filter / light-dark theme toggle / AI summary.

### AI Features (Pro / BYOK)

- **AI Repo Summaries** — Auto-analyze README to generate structured summaries (what it does / tech stack / use cases), cached per repo, prompt to regenerate when source changes.
- **AI Tag Suggestions** — Recommends 3–8 tags with confidence scores, 14 preset category taxonomies, synonymous tag detection.
- **AI Chat** — Repository-level contextual chat, multi-turn memory, code + docs linked.
- **BYOK Multi-Model** — Self-hosted proxy / Gemini / DeepSeek / OpenAI-compatible / Ollama local models. API keys stored only in local Keychain.
- **Hybrid Semantic Search** — BM25 keyword + Embedding semantic search + RRF fusion ranking.
- **AI Settings Panel** — Multi-model switching, fine-grained quota control.

### Trending & Discovery

- **GitHub Trending** — Daily / weekly trending repos, 24h TTL cache.
- **Weekly 3-Source Aggregation** — Ruan Yifeng Weekly / Zread  Hacknew aggregated via backend services, categorized in client, source articles rendered in WebView.
- **Zread Trending** — zread.com weekly trending data source.
- **Backend Services** — 4 Go services (trending / weekly / sharing / wiki), deployed on Fly.io, Bearer Token auth.

### Release Tracking

- **Release Subscription** — Subscribe to repos, push notifications on new releases, unified timeline with read/unread state.
- **Asset Filtering & Download** — Smart filtering by platform / file type, one-click asset download.
- **OpenSSF Scorecard** — Integrated security scoring, radar chart visualization across multiple dimensions, cooldown-based smart refresh.

### Settings & System

- **Cmd+, Settings Panel** — General / AI Service / Storage / About tabs.
- **About Window** — Cmd+I native About Panel, open-source credits list.
- **Window Management** — Default 1800×900, close / minimize / fullscreen, frame persistence.
- **macOS Native** — Liquid Glass design language, Apple App Sandbox, Hardened Runtime.

### Internationalization

- **English & Chinese** — String Catalog (`Localizable.xcstrings`) for all localized strings, supports en + zh-Hans.

### Internal Tooling

- **CodeFlow** — Built-in code graph, dependency visualization, branch-level code analysis.
- **Secrets.xcconfig.template** — Automated script to inject multi-service API keys from `.env`.
- **Makefile** — `setup-production-api-keys` / `sync-fly-secrets` one-command workflows.

---

[1.0.0]: https://github.com/dong4j/starcat/releases/tag/1.0.0
