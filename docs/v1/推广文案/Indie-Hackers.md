# Indie Hackers

## Angle

Indie Hackers is best for build-in-public and product reasoning. Talk about the problem, the first user segment, pricing uncertainty, and why the product is not trying to become a SaaS dashboard.

## Title Options

- Building a macOS app for developers whose GitHub Stars became unmanageable
- From GitHub Stars to a repo research workspace: building Starcat
- I am turning my own GitHub Stars problem into a macOS developer tool

## Post Draft

I am building Starcat, a native macOS app that turns GitHub Stars into a local repo knowledge base.

The problem came from my own workflow. I star a lot of repos while researching developer tools, AI agents, Swift/macOS libraries, databases, CLI utilities, and open-source products. The star action is too easy. After a while, the list becomes hard to use: I forget why I starred something, I cannot find the exact repo I remember, and I rarely go back to digest what I collected.

Starcat's first version is intentionally narrow:

- sync GitHub Stars locally;
- read and cache README files;
- add tags, notes, and reading status;
- search across repos, README content, and notes;
- track releases and activity;
- use AI for repo summaries, tag suggestions, translations, and contextual chat.

I am positioning it as a local-first developer tool, not a hosted SaaS. That matters because a user's Stars list is a pretty personal interest graph. It shows what technologies they are evaluating and what projects they may be building. I want the user's library, notes, and AI cache to remain on their machine by default.

The next product direction is organized around three workflows:

- Organize: batch-tag messy stars, clean up overlapping labels, generate smart collections.
- Discover: find alternatives, get similar repo recommendations, compare candidate projects.
- Digest: weekly summaries, release upgrade notes, and memory search over your own stars.

I am still figuring out the right go-to-market path. Developer communities like HN, V2EX, Reddit, and Product Hunt are obvious launch points, but I suspect the long-term channel is content: repo research posts, GitHub project digests, and technical write-ups around how open-source tools are evaluated.

The biggest open question for me is pricing. AI-heavy workflows could be Pro, but the core value should probably remain usable without AI: search, tags, notes, README reading, and release tracking.

If you have built paid developer tools before, I would be interested in how you drew the line between free utility and paid workflow automation.

