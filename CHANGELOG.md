# Starcat App Store Changelog

Release notes for the Mac App Store edition of Starcat.

## 1.0.0

Initial Starcat release for the Mac App Store.

### Highlights

- Manage GitHub stars in a native macOS three-column app.
- Sign in with GitHub and sync starred repositories with progress, refresh, and rate-limit handling.
- Browse repositories by all stars, tags, languages, smart collections, status, archived state, forks, and search.
- Read repository details with metadata, README rendering, GitHub shortcuts, clone links, and unstar actions.
- Organize repositories with tags, batch tagging, private notes, and reading or usage status.
- Search locally across repository names, owners, descriptions, notes, and related metadata.
- Explore GitHub Trending, weekly sources, recommendations, and repository activity.
- Track repository releases, subscribe to repositories, review assets, and mark updates as read.
- Use AI features with your own provider settings, including repository summaries, tag suggestions, chat, semantic search, README translation, and sharing support.
- Review repository health signals, OpenSSF Scorecard information, Wiki context, and related insights.
- Create and export share cards and repository collections.
- Manage app settings, storage, diagnostics, open-source credits, themes, language, and interface preferences.
- Use English and Simplified Chinese throughout the app.
- Unlock Pro features through Apple in-app purchase.

### New

- Added Getting Started onboarding for sync, AI trials, project homepage, and knowledge base setup, with back navigation and manual replay support.
- Added overlay state protection to prevent onboarding lockout after unexpected exits and refined share guidance placement.
- Added Agent and RAG workbenches as independent system windows with floating pin control, collapsible sidebars, and inherited interface scale.
- Added Agent plan and tool output display, expanded event model, and completed runtime event feedback loop.
- Added similar repository recommendations, saved recommendation results, clearer recommendation cards, starred-repository indicators, and separate repository windows.
- Added more GitHub sign-in choices, including browser-based sign-in, token sign-in, a clearer login chooser, and a visible authorization countdown.
- Added repository code intelligence as a Pro feature, giving each repository its own analysis workspace, cached results, and a dedicated settings entry.
- Added in-detail AI assistant entry, README AI summaries, summary caching, and smoother summary generation.
- Added Browser Plugin workflow for GitHub pages, including local pairing, repository context, notes, tags, health data, Wiki context, recommendations, and Safari WebExtension support.
- Added a getting started checklist to guide first-time setup and key actions.
- Added Explore and discovery surfaces for trending, discovery, GitHub search, and ranked repository lists.
- Added README background fetching and health score prefetching so repository details can feel ready sooner.
- Added health score sorting, health color states, and OpenSSF Scorecard warmup for easier repository evaluation.
- Added menu bar and macOS menu controls for quicker access to common actions.
- Added service status badges, service health checks, and local operations tools for easier setup and troubleshooting.
- Added interface size controls, release timeline paging, and release subscription counts in the sidebar.

### Improvements

- Refined Agent workbench audit visibility, reply styling, toolbar entry points, and title bar controls.
- Refined first-sync and weekly page loading states with shared loading indicators.
- Refined recommendation cards, recommendation caching, placement, starred-repository indicators, and Pro gating.
- Refined README rendering with GitHub image handling, system-style scrollbars, and clear loading states.
- Refined global search with keyboard shortcut, history, reliable focus behavior, and GitHub result pagination.
- Refined GitHub Stars list handling, sidebar counts, language icons, and empty states.
- Refined Activity and Weekly browsing with filters, fast counts, and detail loading states.
- Refined sharing cards with multiple layouts, color options, profile details, and Pro-aware availability.
- Refined Settings copy, storage actions, service configuration, and diagnostic log feedback.
- Refined dark mode support across AI, health, search, sharing, and plugin-related screens.
- Refined action icon patterns across toolbars, dangerous actions, common actions, tags, sidebars, and batch operations.
- Refined internal diagnostics, telemetry safety, and developer-only controls without exposing unfinished features.
- Fixed stable Agent default artifact selection on load.
- Fixed stable RAG and workbench input handling for first-keystroke text entry.
- Fixed RAG middle column message alignment and workbench title bar icon visibility.
- Fixed Dock and menu bar reopening behavior after the main window is closed.
- Fixed cursor behavior when overlays sit above README content or other interactive views.
- Fixed AI summary generation for repositories whose GitHub names differ only by letter case.
- Fixed automatic visible-content refresh after notes or tags are changed from external entry points.
- Fixed stable recommended repository windows and README loading behavior.
- Fixed README image support for nested folders and GitHub raw image paths.
- Fixed global search focus timing and refined search result interactions.
- Fixed storage reset completion states, unsigned-in storage scrolling, and settings layout edge cases.
- Fixed language aggregation sorting for repositories with missing language data.
- Fixed release-build-safe debug-only menu controls.
