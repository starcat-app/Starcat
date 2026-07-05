# Starcat Changelog

All notable changes to Starcat are summarized here for release notes.

## 1.1.0

### New

- Added similar repository recommendations, with saved results, clearer recommendation cards, starred-repo indicators, and the option to open recommended repositories in a separate Starcat window.
- Added more GitHub sign-in choices, including browser-based sign-in, token sign-in, a clearer login chooser, and a visible authorization countdown.
- Added repository code intelligence as a Pro feature, giving each repository its own analysis workspace, cached results, and a dedicated settings entry.
- Added an in-detail AI assistant entry, README AI summaries, summary caching, and smoother summary generation from both Starcat and browser-based entry points.
- Added a Browser Plugin workflow for GitHub pages, including local pairing, repository context, notes, tags, health data, Wiki context, recommendations, and Safari WebExtension support.
- Added a getting started checklist to guide first-time setup and key actions.
- Added Explore and discovery surfaces for trending, discovery, GitHub search, and ranked repository lists.
- Added README background fetching and health score prefetching so repository details can feel ready sooner.
- Added health score sorting, improved health colors, and OpenSSF Scorecard warmup for easier repository evaluation.
- Added menu bar and macOS menu controls for quicker access to common actions.
- Added Direct distribution support alongside the App Store channel, including a separate Direct build target, channel-aware configuration, and Direct-only Sparkle update integration.
- Added Sparkle update support for Direct builds, including an appcast feed, EdDSA key configuration, update menu integration, and documentation for key backup and multi-Mac signing workflows.
- Added Direct license infrastructure with a License API service, local license storage, and a channel-neutral entitlement layer for App Store and Direct builds.
- Added a provider-neutral direct payment abstraction so future payment gateways such as Creem can be integrated without binding the app to one vendor.
- Added service status badges, service health checks, and local operations tools for easier setup and troubleshooting.
- Added interface size controls, improved release timeline paging, and release subscription counts in the sidebar.

### Improved

- Improved recommendation UI placement, card layout, caching behavior, and Pro gating.
- Improved README rendering, including GitHub image handling, system-style scrollbars, and clearer loading states.
- Improved global search with a shortcut, history, better focus behavior, and pagination for GitHub results.
- Improved GitHub Stars List handling, sidebar counts, language icons, and empty states.
- Improved Activity and Weekly browsing with richer filters, faster counts, and clearer detail loading.
- Improved sharing cards with new layouts, color options, better profile details, and safer Pro checks.
- Improved Settings copy, storage actions, service configuration, and diagnostic log feedback.
- Improved dark mode support across AI, health, search, sharing, and plugin-related screens.
- Improved release readiness materials, open-source credits, distribution planning, and in-app release notes loading.
- Improved Direct release tooling with separate App Store and Direct packaging scripts, Direct run targets, Sparkle appcast generation, and a release orchestration script for uploading appcast and DMG files.
- Improved the Starcat website nginx configuration for Sparkle updates by adding no-cache appcast handling and explicit Direct download rules.
- Improved shared action icon patterns across toolbars, dangerous actions, common actions, tags, sidebars, and batch operations.
- Improved internal diagnostics, telemetry safety, and developer-only controls without exposing unfinished features as product features.

### Fixed

- Fixed cases where closing the main window could prevent Dock or menu bar reopening from restoring Starcat correctly.
- Fixed cursor behavior when overlays sit above README content or other interactive views.
- Fixed AI summary generation for repositories whose GitHub names differ only by letter case.
- Fixed browser plugin actions so unavailable or Pro-only actions are handled more clearly.
- Fixed notes and tags changed from external entry points so Starcat can refresh the visible content automatically.
- Fixed recommended repository windows that could crash or leave README content stuck loading.
- Fixed multiple CodebaseMemory launch, storage, cache, and repository-switching issues.
- Fixed README images in subdirectories and GitHub raw image paths.
- Fixed global search focus timing and several search result interaction details.
- Fixed storage reset completion, unsigned-in storage scrolling, and several settings layout edge cases.
- Fixed language aggregation sorting when language data is missing.
- Fixed a release-build issue related to debug-only menu controls.
- Fixed Direct build signing and entitlement checks so non-App Store builds run without the App Sandbox entitlement while App Store builds keep their sandbox configuration.
- Fixed Direct update test packaging so temporary versions can override marketing/build versions and appcast generation no longer includes stale DMG files.

## 1.0.0

Initial Starcat release.

### Highlights

- Manage GitHub stars in a native macOS three-column app.
- Sign in with GitHub and sync starred repositories with progress, refresh, and rate-limit handling.
- Browse repositories by all stars, tags, languages, smart collections, status, archived state, forks, and search.
- Read repository details with metadata, README rendering, GitHub shortcuts, clone links, and unstar actions.
- Organize repositories with tags, batch tagging, private notes, and reading or usage status.
- Search locally across repository names, owners, descriptions, notes, and related metadata.
- Explore GitHub Trending, weekly sources, recommendations, and repository activity.
- Track releases, subscribe to repositories, review assets, and mark updates as read.
- Use AI features with your own provider settings, including repository summaries, tag suggestions, chat, semantic search, README translation, and sharing support.
- Review repository health signals, OpenSSF Scorecard information, Wiki context, and related insights.
- Create and export share cards and repository collections for external sharing.
- Manage app settings, storage, diagnostics, open-source credits, themes, language, and interface preferences.
- Use English and Simplified Chinese throughout the app.
- Run as a native macOS app with sandboxing, hardened runtime, window management, and App Store readiness work in place.

[1.1.0]: https://github.com/dong4j/starcat/releases/tag/1.1.0
[1.0.0]: https://github.com/dong4j/starcat/releases/tag/1.0.0
