# Hacker News / Show HN

## Positioning

HN users usually dislike launch-copy. Be specific, technical, and honest about what is done versus planned.

## Title

Show HN: Starcat – a native macOS app for organizing and researching GitHub Stars

## Post Draft

Hi HN,

I built Starcat because my GitHub Stars had turned into a graveyard of "I'll look at this later".

Starcat is a native macOS app that syncs your GitHub Stars locally and turns them into a searchable repo knowledge base. The first version focuses on the boring but useful workflow: sync stars, read README files, add tags/notes/status, track releases, search locally, and use AI only when it has repo context.

Screenshots:

![Manage view](assets/01-manage-ungrouped.png)

![Repo detail](assets/02-repo-detail-readme.png)

Some implementation details that might be interesting:

- SwiftUI native macOS app, not Electron.
- Local SQLite/GRDB cache for repos, README content, tags, notes, status, AI results, and search data.
- README rendering is cached and refreshed in the background.
- AI summaries, tag suggestions, translation, and repo chat run against the current repo context. The app supports user-configured AI providers instead of forcing a hosted model.
- AI suggestions do not write to the library automatically. Tags, notes, and future agent outputs need explicit user confirmation.
- There is also a local MCP service so other local agents can query Starcat's repo/search context.
- Similar-repo recommendations are currently routed through a small `starcat-recommend-api` boundary. The first provider is SimRepo; the client consumes a stable endpoint so the backend can later move to a self-hosted content/vector recommendation system.

What I am exploring next is not a generic chatbot. I am trying to shape the product around three workflows:

- Organize: batch-tag unclassified stars, clean up overlapping tags, generate smart collections.
- Discover: find alternatives, compare candidate repos, generate technical research reports with citations.
- Digest: weekly summaries of newly starred repos, release upgrade notes, memory search over your own stars.

I would like feedback on two things:

1. If you have hundreds or thousands of GitHub Stars, how do you manage them today?
2. For repo research, would you rather have AI produce short summaries, comparison tables, or longer reports with citations?

Happy to answer implementation questions.
