# Starcat App Store Changelog

Release notes for the Mac App Store edition of Starcat.

## 1.2.0

Starcat 1.2.0 focuses on stability, usability, and visual polish—adding an 18-language interface, pinning, share links, shortcuts, and README capabilities, while refining navigation, tags, notes, translation, and knowledge-base flows.

### New

- 18-language interface: Use Starcat in English, Simplified Chinese, Traditional Chinese, Japanese, Korean, German, French, Spanish, Brazilian Portuguese, Italian, Russian, Dutch, Polish, Ukrainian, Turkish, Vietnamese, Indonesian, or Arabic.
- Repository pinning in Manage: Pin / Unpin, most-recently-pinned ordering, and a card-corner indicator.
- Repository share links: Open Starcat and locate the shared repository.
- Customizable app shortcuts: Search, refresh, open Knowledge RAG workspace and current-repo AI, with global and per-shortcut switches.
- README Mermaid diagrams: Local rendering with responsive sizing in narrow detail panes, and source fallback when rendering fails.
- README segmented and full translation: Segmented bilingual reading by default; full mode replaces visible text while keeping README structure.

### Improvements

- Add-tag popover: Clearer colored-icon rows and selection, with a solid window-matched background.
- Pro sidebar username gradient: Better light/dark adaptation, smoother first-letter color, and stronger light-mode contrast.
- Starred and Explore navigation: Clearer three-level hierarchy and filter context.
- README translation speed: Smaller first batch, incremental results, up to four concurrent requests, per-segment caching, and resume for unfinished segments.
- Personal notes: README-based AI generate/refine, visible progress, Markdown edit/preview, draft copy, and clearer save status.
- AI sharing: Reuse existing AI summaries; cancel creation and regenerate share links.
- Knowledge-base chunk management: Shard counts match language/stars sizing on cards; edit and detail views show last-updated time and approximate token counts.

### Fixes

- Knowledge Base entry: Fixes occasional no-response, minimized-window restore failure, and opening empty-library setup before index status finishes loading.

## 1.1.0

Starcat 1.1.0 turns saved repositories into a local-first, explainable RAG knowledge base, with broad performance, reliability, and macOS interface improvements.

### New

- Added a full knowledge-base RAG workspace with multi-repository context, streaming answers, citations, conversation groups, pinning, history, and draft recovery.
- Added hybrid retrieval across vector and bilingual keyword search, repository metadata, Wiki, RepoContext, optional reranking, live GitHub context, and external search.
- Added knowledge-base browsing and index management with batch Star imports, README completion, chunk editing and exclusion, targeted rebuilds, and index health checks.
- Added explainable RAG controls for query plans, execution timelines, retrieval funnels, context budgets, historical replay, retrieval settings, and debug export.
- Added a local AI usage dashboard for requests, tokens, latency, and failures without storing prompts or response content.
- Added global Star-status filters and AI-summary indicators for faster repository triage.

### Improvements

- Improved large-library and long-conversation performance with bounded indexing, batched vector work, incremental persistence, limited prefetching, and caching.
- Improved the RAG workspace with resizable columns, loading skeletons, richer citation panels, code and table copying, stable scrolling, and responsive typography.
- Improved AI settings and background jobs with clearer model capabilities, safer tag suggestions, actionable diagnostics, progress reporting, and cancel or skip controls.
- Improved Explore, Trending, and Weekly with shared snapshots, session caches, cancellation-safe switching, source filters, timelines, and stable loading states.
- Improved native macOS consistency across settings, pickers, segmented controls, sidebar icons, semantic colors, and compact window layouts.
- Improved browser Companion workflows with configurable local ports, recommendation pagination, Star-state synchronization, and clearer availability feedback.

### Fixes

- Fixed RAG scope isolation across repository or account switches, concurrent tasks, cancellations, and stale callbacks.
- Fixed retrieval and citation correctness for explicit repository scopes, private notes, bilingual keywords, Wiki content, excluded chunks, false citation markers, and no-evidence refusal.
- Fixed conversation stability for title generation, pin ordering, draft and history restoration, long-session compression, streaming timers, and scroll-to-bottom behavior.
- Fixed knowledge-base refresh and indexing issues, including unnecessary reloads, stale vectors overwriting new chunks, inaccurate source updates, and background Wiki refresh failures.
- Fixed browser-based GitHub sign-in, localized AI and RAG error feedback, and several settings, layout, and accessibility issues.

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
