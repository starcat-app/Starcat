# Product Hunt

## Product Name

Starcat

## Tagline

Turn GitHub Stars into an AI-readable knowledge base

## Short Description

Starcat is a native macOS app for developers who have outgrown GitHub's basic Stars page. Sync your Stars locally, search README content, organize repos with tags and notes, track releases, and ask AI about any repo with your own provider.

## Gallery Notes

Use these screenshots:

1. `assets/01-manage-ungrouped.png` — "Your Stars, finally organized."
2. `assets/02-repo-detail-readme.png` — "Read README files, notes, tags, releases, and repo context in one place."
3. `assets/04-ai-assistant-window.png` — "Ask AI about the repo you are already reading."

## Maker Comment

Hi Product Hunt,

I built Starcat after realizing my GitHub Stars were no longer useful as a simple bookmark list.

Like many developers, I star repos constantly: libraries I may use later, tools I want to compare, AI projects I want to follow, articles hidden inside README files, and frameworks I might need for a future project. After a while, the list becomes hard to search, hard to review, and almost impossible to turn into actual knowledge.

Starcat is my attempt to fix that on macOS.

The first version focuses on a local-first workflow:

- Sync GitHub Stars into a native macOS app.
- Read and cache README files.
- Add tags, notes, and reading status.
- Search across repo metadata, README content, and personal notes.
- Track releases and activity.
- Generate AI summaries, tag suggestions, translations, and repo-specific chat using your configured provider.
- Discover similar repositories from the repo detail page.

The AI part is intentionally conservative. Starcat does not auto-edit your library. AI can suggest tags or draft notes, but the user confirms before anything is written.

The larger direction is to make Starcat a repo research workspace, not just a Star manager. I am exploring three lines:

- Organize: clean up messy stars, batch-tag unclassified repos, generate smart collections.
- Discover: similar repos, alternatives, technical selection reports.
- Digest: weekly summaries, release upgrade notes, memory search over your own stars.

I would love feedback from developers who have a large GitHub Stars library or regularly research open-source tools before choosing what to adopt.

## Launch Tweet

I launched Starcat today: a native macOS app that turns GitHub Stars into a searchable, AI-readable repo knowledge base.

Sync stars locally, read README files, add notes/tags, track releases, and ask AI about the repo you are viewing.

Built for developers whose Stars became "I'll look at it later."

