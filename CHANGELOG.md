# Starcat App Store Changelog

Release notes for the Mac App Store edition of Starcat.

## 1.6.0-待发布

Starcat 1.6.0 focuses on performance and detail polish: lower background load at launch, smoother scrolling and long lists, and lighter rendering in high-frequency views. It also adds a privacy settings page and an Owner profile card, brings OrcaRouter models and Firecrawl search, and continues refining Settings, Knowledge Base, and sharing.

### New

- OrcaRouter provider: Add OrcaRouter as an AI provider for summaries, tagging, and knowledge base Q&A.
- Firecrawl web search: Add Firecrawl as a web search provider with domain filtering and full-page fetching; some providers can now be enabled without an API key.
- Owner profile card: Click an owner name in the repository detail header to view their avatar, bio, social links, and stats, and follow or unfollow them.
- Language distribution bar: Repository detail gains a language usage bar; hover to see each language's share and click to filter repositories by language.
- Missing tag auto-creation: AI tag auto-apply can now create missing tags and apply them immediately; the option is off by default.
- Cache usage overview: Settings now groups cache usage into Content, Discover, AI, and Code categories.
- Privacy settings: A new dedicated privacy page centralizes sign-in scope and public data contribution controls.
- Sign-in scope disclosure: The privacy settings page shows the GitHub OAuth scopes requested at sign-in and notes organization authorization limits.

### Improvements

- Native Settings experience: Uses a macOS-style sidebar, search, and back/forward navigation in a fixed-size Settings window.
- Unified RAG configuration: Inference, prompt, and retrieval controls now live in the main Settings window, save automatically, and present prompt helpers and retrieval options without extra nested navigation.
- Language categories: Star and Explore language lists now follow your interested languages and add "Other" and "Uncategorized" groups to reduce clutter.
- AI tag review: Batch selection and select-all for repositories, highest-confidence tags and groups preselected by default, and suggestions that distinguish existing from new tags.
- Smart collections: Create collections directly from the My Collections header; smoother waterfall scrolling and tighter built-in cards.
- Repository detail toolbar: The clone menu merges into the external links menu, and repositories opened externally pin temporarily to the top of the list for quick locating.
- RAG workspace: The conversation header shows the creation time, and new conversations reuse an existing empty one instead of piling up blank sessions.
- Owner profile card: Refined light and dark styling, and the contribution snake animation runs off the main thread so module switching stays smooth.
- List performance: Explore sub-pages lazy-load; pagination appends incrementally and reuses filter results, smart collection stats load concurrently, and avatars reuse the image cache for smoother long lists.
- Interface polish: Explore cards fade in row by row, the library list shows a starred checkmark, and module transitions and empty states read better.
- Startup and scrolling performance: Unchanged Spotlight indexes are skipped for lower background load at launch, and scrolling no longer triggers unnecessary prefetching and hover refreshes.
- Rendering performance: High-frequency areas such as repository detail switching, the library list, and the Agent execution timeline re-render less, keeping interactions snappier.
- Conversation sidebar: RAG conversations sort by recent activity, groups expand to show more history, and the brand icon adapts to light and dark themes.
- Share entry: A unified repository share entry with slimmer list-row actions and a more compact share card.
- Visual polish: Multi-select toggles move into each list's header bar, the repository detail empty state uses a 3D transparent illustration, and action icon backgrounds are unified, with Release timeline assets matching the insights page style.

### Fixes

- Library smart collection paging: Continues loading repositories in full-screen layouts and after fast scrolling to the bottom instead of getting stuck on the current page.
- Trending scrolling: Fixes laggy scrolling for a smoother browse.
- AI workspace windows: Fixes split-layout freeze loops, oversized width with the inspector open, content clipping when dragging the sidebar at minimal window sizes, and main-window reopen issues.
- Search input: Fixes pressing Return while a Chinese input method is composing, and keys being swallowed during global search composition; after a search, the current repository row is located automatically.
- Awesome explore: Fixes source status display and card language-bar anomalies.
- Activity replies: Sent replies now appear immediately in the timeline instead of being delayed or overwritten by stale content.
- Release assets: "Open" after a completed download now reveals the file in Finder.
- Skeleton colors: Fixes overly bright skeletons in light mode, with softer contrast in both themes.
- Settings sidebar: Limits the settings sidebar drag range.
- Owner heatmap: Fixes the contribution lawn not refreshing after a theme switch.
- Discover paging: Fixes pagination not triggering while fast-scrolling Discover categories.
- Service settings: Fixes action icons being squeezed out of service settings fields at narrow window widths.
- RAG project panel: Fixes Return accidentally switching the active context.

## 1.5.0

Starcat 1.5.0 expands how you discover, organize, and revisit GitHub repositories with Awesome discovery, Spotlight search, GitHub Lists and batch AI organization, GitHub contribution widgets, and richer Activity conversations, README reading, and repository insights.

### New

- Awesome discovery: Find projects through Starcat Picks or custom Awesome sources, browse by source and section, search, filter, select repositories in bulk, and review repository files and external resources.
  ![20260829182340_PnJngNwc](https://cdn.dong4j.site/source/image/20260829182340_PnJngNwc.webp)
- Awesome source management: Add public GitHub Awesome repositories as sources, follow background parsing progress, refresh them manually, and keep using local results when the network is unavailable.
- Spotlight repository search: Search starred repositories and local notes from macOS Spotlight, then open Starcat directly at the matching detail. The repository header can also copy the full name.
  ![20260829182425_jmMVz8Xz](https://cdn.dong4j.site/source/image/20260829182425_jmMVz8Xz.webp)
- GitHub Lists organization: Add repositories to multiple GitHub Lists and generate AI grouping suggestions. Preview, filter, and adjust results before applying them, create groups, discard suggestions, or regroup repositories.
  ![20260829182513_ys1fvp7q](https://cdn.dong4j.site/source/image/20260829182513_ys1fvp7q.webp)
- Batch AI workspace: Select repositories to generate summaries, tags, and grouping suggestions through one task queue and review them in the same window. Code context and external search can be chosen for each task.
- Automatic AI organization: Configure the GitHub Lists scope and schedule. Human review remains the default, with an optional user-enabled automatic confirmation setting.
- GitHub contribution widgets: Add Contribution Overview, Contribution Summary, yearly heatmap, and contribution radar widgets for today’s activity, best day, totals, commits, issues, pull requests, reviews, and repositories.
- GitHub service status: The main-window status panel now shows the official GitHub service status.
- README in-page search: Press Command-F in a README to open the find bar and step through matches. List search defaults to Shift-Command-F, and both shortcuts can be changed in Settings.
- Repository documents and videos: Open same-repository Markdown documents in a separate Starcat window and play supported GitHub README videos with native controls.
  ![20260829182717_qiV7h8Uy](https://cdn.dong4j.site/source/image/20260829182717_qiV7h8Uy.webp)
- Security advisories and release assets: Review recent advisories, severity, and GHSA / CVE details in Insights, then browse, copy, or download the latest release attachments.
  ![20260823013144_YdoureTM](https://cdn.dong4j.site/source/image/20260823013144_YdoureTM.png)
- Background Activity notifications: While Starcat is running, receive Issue, pull request, and Discussion updates without opening Activity, with distinct closed, reopened, and merged state changes.
- Activity status and filters: Issues and pull requests show Open, Closed, or Merged, while Star, Unstar, and Fork events show whether the repository is in your library and support combined status filters.
- Issue conversation actions: See opening titles, labels, and event history; paste images, preview Markdown, copy links or content, quote replies, and edit your own opening posts and comments.
  ![20260829182919_ACzqn6YW](https://cdn.dong4j.site/source/image/20260829182919_ACzqn6YW.webp)
- Public Star contribution: An optional, off-by-default privacy setting can anonymously contribute public repository IDs and available Star dates to improve recommendations without blocking normal sync.
- Sharing and open-source links: Copy share text from repository health, repository insights, and library statistics. Share cards and exports identify Starcat, while Help and About link to the source repository.
- Star trend image sharing: Copy the Star trend card from Repository Insights as an image, preserving repository identity and avatar for saving or sharing.

### Improvements

- Awesome browsing: Sources, sections, and repositories now load incrementally with stable pagination, improved source search, real descriptions, repository metadata, refresh progress, and a three-column layout.
- AI organization workflow: Ungrouped organization starts from a middle-column banner and can create groups before processing. The task queue shows avatars, descriptions, status totals, and review results, and unfinished sessions can be discarded or continued.
- AI processing performance: Batch summaries, tags, and grouping tasks use bounded parallel processing, publish each repository’s result as it finishes, and keep large review lists and windows responsive.
- Long-list loading: Activity, Explore, Awesome, Releases, Knowledge Base, and AI review lists now prefetch consistently so fast scrolling is less likely to miss the next page.
- AI usage statistics: The usage dashboard adds estimated cost, pricing coverage, and persisted snapshots for comparing model and task consumption.
- Desktop widgets: Focus, Repository Rediscovery, Collection Trend, and Release Watch have clearer hierarchy and heatmap layouts. Sparse large-size variants have been removed.
- Local Issue state: Comments, event history, and unsent drafts are cached per thread and survive thread changes or app restarts; each cache can be cleared in Settings.
- Release asset downloads: See live progress in each download row, then use the completion toast to find or open the saved file.
- Tag and list editing: Choose tag-merge targets in a sheet with predictable ordering and default selection, with consistent headers across tag and GitHub List editors.
- Interface details: Shortcut modifiers and primary keys use separate keycaps, the empty Activity detail guides selection, and suggested tags use clearer rows and hover feedback.

### Fixes

- Account data isolation: Restoring a cached session switches to the matching account database before publishing the signed-in state, avoiding temporary reads or writes against another account.
- Release notes images: Screenshots in the Activity timeline now scale to the window width instead of being clipped.
- README and comment translation: Switching repositories or conversations no longer mixes translation state, and opening posts plus every comment can show the correct side-by-side translation.
- Comment box on thread change: Switching Issues immediately stops AI generation and collapses the composer so drafts do not carry into another thread.
- Activity library state: Adding a repository from the timeline updates only its library badge without closing the current detail or resetting the selection.
- Star count synchronization: After starring or unstarring in Manage, Explore, or Activity, list and detail counts update immediately and remain consistent.
- Repository community signals: Directory-based GitHub Issue Forms are recognized correctly instead of appearing missing.
- AI summary overlay: The expanded panel stays below the README / Insights tabs instead of covering page navigation.

## 1.4.0

Starcat 1.4.0 brings GitHub Notifications into Activity so you can handle mentions, review requests, and Issue / PR threads without leaving the app, while continuing to refine knowledge-base indexing and Explore.

Important update: Starcat's online services have been upgraded. Please update to 1.4.0 as soon as possible. Older versions can still display existing local cache, but online refresh, recommendations, Discovery, Wiki, and sharing will no longer be available.

### New

- GitHub notification inbox: Review mentions, review requests, assignments, discussions, releases, and security alerts in Activity. Filter by Unread, Mentions, Reviews, Issues, PRs, and more; group by Today, Yesterday, This week, and Earlier. All also interleaves your own Stars, Unstars, and Forks. The timeline distinguishes Issues from PRs; avatars and usernames open GitHub profiles, and Dependabot uses its official circular mark. Viewed items stay read, and the sync control spins while refreshing. Starcat asks to re-authorize if notification access is missing, and can post reminders in Notification Center.
  ![20260820212317_QsP1FsMm](https://cdn.dong4j.site/source/image/20260820212317_QsP1FsMm.png)
- Issue / PR threads: Open a notification to read the opening post and comments, write or preview a reply, and move to the previous or next item. Done matches GitHub Inbox Done and does not close the issue. Confirmed-open issues can be closed; closed issues can be reopened. Open the thread on GitHub, or the repository in Starcat.
- AI comment drafts: Generate a reply from the current thread, or polish text you already typed. The reply follows the thread language, not your draft or the app UI language.
- Thread translation: Translate the opening post and comments in segmented or full mode; titles, repository names, and the composer stay original. Target language can follow the app UI, paragraphs already in that language are skipped, and new translations fade in briefly.

### Improvements

- Long thinking smoothness: Knowledge Q&A and repository AI chat stay responsive during long reasoning, and you can still expand to read the full text when it finishes.
- Last AI-index prefetch: Opening Settings shows when the last prefetch finished, with counts and green, orange, or red status icons.
- External index test status: Meilisearch and Qdrant each show their own result next to Test and Save, with green success, orange rebuild-needed, and red failure icons.
- Semantic search progress: Index refresh shows a busy ring immediately, then a determinate ring as up-to-date repos are skipped; only missing or stale vectors are rebuilt.
- Semantic relevance badge: Percent size matches Language, Stars, and Forks on the same row.
- Knowledge-base chunk status: Details distinguish whether a shard is still in the library from current-model embedding status.
- Knowledge-base embedding progress: Shows current-model coverage, no longer marks a previous run as finished, and can be viewed or paused from the toolbar status panel.
- Index issue shards: Open the knowledge base from pending, failed, or expired cards and jump to the matching chunk.
- Meilisearch keyword index: Text is synced at the start of a knowledge-base rebuild so keyword search works before embeddings finish.
- Knowledge-base Chinese search: Chinese infix matching, and named repositories more reliably land on indexed README content.
- Shortcut recorder: Expands the key display area and shows an inline reset-to-default control only after a shortcut is changed.
- README translation: Target language can be Auto (follows the app UI), same-language paragraphs are skipped, and new translations fade in briefly.
- Translation and AI-draft errors: Failures show as a bottom-right toast; incomplete AI setup can open Settings.
- First-run coaching: Replaces overlapping system tips with a single yellow capsule.
- Activity counts and help: List counts move to the system title-bar subtitle, and category help opens from the middle column.
- Notification timeline pagination: Preloads the next page around eight items before the end, keeping long timelines moving without waiting at the bottom.

### Fixes

- Query planning timeline: Thinking is nested under Query planning, and the plan plus Context Plan panel appear only after planning actually finishes.
- Embedding cancel: Pausing vectorization no longer reports a network error or bounce the progress back.
- Global filter panel: Removes the noticeable delay when opening repository filters for faster access.
- Explore offline cache: Shows cached Discovery, Popular, and New Releases data immediately when the service is unavailable instead of leaving skeleton rows visible.
- Explore category counts: Restores cached Discovery, Popular, New Releases, and Weekly totals on first launch without opening each category.

## 1.3.0

Starcat 1.3.0 adds My Projects, library-wide and repository-level insights, macOS desktop widgets, reusable insight context for AI and RAG, and external search integrations for Alfred, uTools, and Raycast—helping you manage, understand, and rediscover repositories faster.

### New

- App Store update checks: Automatically detect new versions at launch or when the app becomes active, with manual checks from the Actions menu and menu bar and a shortcut to upgrade in the Mac App Store.
- My Projects: Browse personal, organization, and external collaboration repositories; use GitHub App permissions for authorized public, private, and internal projects, with existing filters, details, and Star trends.
- My Insights: Review organization progress, technology distribution, project status, and items needing attention across all saved repositories or your Knowledge Base, then drill down to the matching repository list.
  ![20260730232032_p1AUnCiu](https://cdn.dong4j.site/source/image/20260730232032_p1AUnCiu.webp)
- Repository Insights: View Star growth, collaboration activity, commit trends, contributors, release cadence, project health, community standards, and security signals, with stable content while switching repositories or refreshing.
  ![20260730224524_01AnNgnJ](https://cdn.dong4j.site/source/image/20260730224524_01AnNgnJ.webp)
- Repository Insights Context: Reuse generated insights in AI summaries, repository conversations, and RAG answers through a removable read-only XML context, with distinct status for unavailable data, custom prompts that omit insights, and actual fallback.
- macOS desktop widgets: Starcat Focus, Rediscovery, Release Watch, and Star Trend show frequently used repositories, a daily rediscovery, unread releases, and recent starring growth with deep links to the corresponding content.
  ![20260730231856_O82ii1o3](https://cdn.dong4j.site/source/image/20260730231856_O82ii1o3.webp)
- Alfred Workflow: Search Starcat local repositories and GitHub directly from Alfred. [View project](https://github.com/starcat-app/starcat-alfred-workflow)
- uTools Plugin: Search Starcat local repositories and GitHub directly from uTools. [View project](https://github.com/starcat-app/starcat-utools-plugin)
- Raycast Extension: Search Starcat local repositories and GitHub directly from Raycast. [View project](https://github.com/starcat-app/starcat-raycast-extension)

### Improvements

- Shared insight aggregates: My Insights and repository insights data are used as context for RAG knowledge base Q&A.
- RAG Prompt Settings: Compare and copy read-only default prompts, with clearer Markdown formatting for Q&A and conversation compression templates.
- Custom Prompt Diagnostics: See which context capabilities and placeholders a custom template supports without Starcat automatically rewriting user content.
- First-run onboarding: Feature screenshots, refined welcome audio timing, clearer card hierarchy, and more stable window sizing.

### Fixes

- Share card theme controls: Uses full, contiguous click targets for style and color controls, eliminating missed clicks near edges and between buttons.
- RAG evidence citations: Metadata found through keyword search and Knowledge Base statistics now appear as actual cited snippets, so sources remain verifiable in answers and conversation history without vector indexing.

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
