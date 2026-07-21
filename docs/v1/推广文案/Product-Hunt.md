# Product Hunt

## Product Name

Starcat

## Tagline

Turn GitHub Stars into a local-first knowledge base you can actually ask questions to

## Short Description

Starcat is a native macOS app that transforms GitHub Stars from a flat bookmark list into a searchable, AI-readable repo knowledge base. Sync stars locally, read READMEs, organize with tags and notes, ask cross-repo questions with local RAG, and connect your AI toolchain via MCP.

## Gallery Notes

Use these screenshots:

1. `assets/01-manage-ungrouped.png` — "Your Stars, finally organized in a native macOS workspace."
2. `assets/02-repo-detail-readme.png` — "Read READMEs, notes, tags, releases, and AI context in one place."
3. `assets/04-ai-assistant-window.png` — "Ask AI about your repos, or open the RAG workspace for cross-repo Q&A."

## Maker Comment

Hi Product Hunt,

I'm dong4j. A year ago, I realized my GitHub Stars had become useless.

Not because GitHub is bad — but because starring is too easy. Click, and it's saved. Click, click, click. After a few years, I had over 2,000 starred repos and no way to find the one I actually needed. I spent 20 minutes scrolling through pages, trying to remember the name of a Swift clipboard manager I had starred months earlier.

So I built Starcat. It's a native macOS app (SwiftUI, not Electron) that treats your GitHub Stars as what they actually are: a personal map of tools, libraries, frameworks, and ideas you once thought were worth remembering.

**What it does today:**

- Syncs your GitHub Stars into a native three-column macOS workspace.
- Caches and renders READMEs locally, so you can read them offline.
- Lets you add tags, notes, and reading status to organize repos your way.
- Full-text search (FTS5) + semantic search (local embedding + cosine similarity).
- AI summaries, tag suggestions, README translation, and contextual repo chat.
- Release tracking and Trending/Weekly feeds.
- Similar repo recommendations (routed through a dedicated API boundary for future swap-in of custom recommendation engines).

**The feature I'm most excited about — Knowledge Base RAG (v1.1.0):**

This is a dedicated RAG workspace that lets you ask natural-language questions across your knowledge base — the repos you've actively added to your library, not all your stars. Want to know "which of my saved SwiftUI projects use Core Data?" That's not a search query. It's a question that requires understanding semantics, then retrieving and synthesizing information across multiple repos.

Starcat does this with a local hybrid retrieval pipeline: FTS5 full-text + local vector search (vDSP-accelerated, ~23x faster than pure Swift), with an optional remote reranker. Every answer comes with citations linked back to specific chunks in your knowledge base. No hallucinated repos. No auto-writing to your library — RAG is read-only.

**For AI toolchain users:**

Starcat also exposes a local MCP Service. Claude, Codex, or any MCP-compatible agent can query your stars, search your repos, and pull structured repo context via RepoContextPacker. There's also a Go-based cross-platform CLI (`starcat-app/starcat-cli`) that bridges everything from the terminal.

**Why local-first matters here:**

Your GitHub Stars are a personal interest graph. They show what technologies you're evaluating, what you're building, and what you're learning. Starcat keeps your data — stars, tags, notes, README cache, AI results, RAG index — on your Mac by default. You choose the AI provider (OpenAI-compatible, DeepSeek, OpenRouter, Ollama, etc.).

**The bigger direction:**

I'm organizing Starcat around three workflows:
- **Organize**: clean up messy stars, batch-tag, merge overlapping labels, generate smart collections.
- **Discover**: find alternatives, get similar repo recommendations, produce technical selection reports with citations.
- **Digest**: weekly summaries of newly starred repos, release upgrade notes, memory search ("what was that SSR framework I starred last year?").

All of Starcat's code is open source at [github.com/starcat-app](https://github.com/starcat-app), with separate repos for the main app, backend services (recommend, trending, weekly, sharing, wiki, discovery), CLI tool, and agent skill definitions. Bug reports and feature requests go to `starcat-app/starcat-pro`.

Would love feedback from developers with large GitHub Stars libraries, people doing open-source research, and anyone who's tried to build local RAG on macOS.

Website: https://starcat.ink

## Launch Tweet

I launched Starcat today: a native macOS app that turns GitHub Stars into a local-first knowledge base you can ask questions to.

- Local stars sync + README reading + tags + notes
- Knowledge Base RAG: cross-repo Q&A with citations (local hybrid retrieval)
- MCP Service for AI toolchain integration
- Local-first, BYOK

Built for developers whose Stars became "I'll look at it later."
