# Hacker News / Show HN

## Positioning

HN users usually dislike launch-copy. Be specific, technical, and honest about what is done versus planned. Focus on architecture decisions, tradeoffs, and implementation details rather than product pitch.

## Title

Show HN: Starcat — a native macOS app with local Hybrid RAG for GitHub Stars research

## Post Draft

Hi HN,

I built Starcat because my GitHub Stars turned into a graveyard of "I'll look at this later." After 2,000+ stars, I couldn't find repos I knew I had saved, couldn't remember why I starred them, and couldn't answer simple questions like "which of my saved projects use Core Data?"

Starcat is a native macOS app (SwiftUI, SQLite/GRDB, local embedding + vDSP vector search) that syncs your GitHub Stars locally and turns them into a searchable, queryable knowledge base. The thing I want to show today is the local Hybrid RAG pipeline I just shipped in v1.1.0.

Screenshots:

![Manage view](assets/01-manage-ungrouped.png)

![Repo detail with AI](assets/02-repo-detail-readme.png)

### The RAG architecture

**Data boundary: Knowledge Base, not all Stars.**

This was the first architectural decision. Stars are a noisy signal — many people star things they never revisit. RAG over all stars produces low-quality retrieval and erodes trust in answers.

Starcat already had a concept of "Knowledge Base" (`library_state = in_library`) — repos the user has explicitly added to their library. RAG defaults to this scope. Users can optionally attach GitHub issues/PRs/releases/security advisories as temporary remote context for a single query, but remote data never enters the local RAG index.

**Retrieval: Local-First Hybrid.**

```
Query
  ├─→ FTS5 full-text (local SQLite, BM25)
  ├─→ Local vector search (local embedding + cosine similarity)
  └─→ Optional: remote reranker (user-opted-in)
       ↓
  Score fusion → Top-K chunks → Prompt assembly → LLM generation
```

Both retrieval channels are local by default. The user chooses their own AI provider for embedding and generation (OpenAI-compatible, DeepSeek, OpenRouter, Ollama). The RAG pipeline works without remote services — the only network call is the final LLM generation (and even that can be local via Ollama).

**Vector search: vDSP acceleration.**

With ~18,000 chunks across 300+ knowledge base repos, naive Swift cosine similarity was too slow. Moving the dot product and L2 norm computation to Apple's vDSP framework (Accelerate) gave a ~23x speedup on the same dataset. This means real-time retrieval without a server-side vector database.

**Chunk-level indexing, not repo-level.**

The existing `repo_embeddings` table answers "which repo is relevant?" but can't locate evidence. For RAG, each README, user note, and AI summary is split into chunks with metadata (source repo, source file, paragraph position). The LLM prompt requires inline citation markers, and the frontend renders them as clickable links that jump to the exact source paragraph.

**Read-only by design.**

RAG does not write to the user's library. No auto-tagging, no auto-notes, no status changes. This is an explicit product constraint: the user's knowledge base is a long-term personal asset, and silent AI writes destroy trust. All AI suggestions (tags, notes) require explicit user confirmation before writing, in a separate non-RAG flow.

### Other implementation details

- **Native macOS, not Electron.** SwiftUI + GRDB (SQLite wrapper) + WKWebView for README rendering. Three-column layout with configurable widths.
- **Similar repo recommendations** are routed through a small `starcat-recommend-api` boundary service. The client consumes a stable `/api/v1/repos/{repo_id}/recommendations` endpoint; the backend can swap from SimRepo to a custom content/behavior hybrid recommendation engine without client changes.
- **Local MCP Service** lets Claude, Codex, or other MCP-compatible agents query the user's stars, search repos, and pull structured context via RepoContextPacker. A Go-based CLI (`starcat-app/starcat-cli`) bridges everything from the terminal.
- **Multi-service architecture**: the main app and supporting services (recommend, trending, weekly, sharing, wiki, discovery) live in separate repos under [github.com/starcat-app](https://github.com/starcat-app). All backend services expose a `/ping` endpoint with injected version info for health checks. Bug tracker at `starcat-app/starcat-pro`.

### What I'm exploring next

Not a generic chatbot. Three workflow lines, all grounded in the user's own repo knowledge base:

- **Organize**: batch-tag unclassified stars, detect and merge overlapping labels (e.g., `cli-tool` vs `cli-tools`), scan for abandoned or functionally-overlapping repo clusters, generate Smart Collections from natural language.
- **Discover**: alternative discovery agent, technical selection reports with citation-backed comparison tables, shortlist evaluation across maintenance activity, license risk, and ecosystem health.
- **Digest**: weekly summaries of newly starred repos clustered by topic, release upgrade notes with breaking-change emphasis, memory search ("what was that SSR framework I starred last year?").

### Questions for HN

1. Local vs. server-side vector DB: for a single-user macOS app with ~10k-50k chunks, is the vDSP approach sustainable, or should I plan for a local vector DB (Qdrant/Milvus embedded) at a certain scale?
2. Chunk strategy: I'm currently splitting on paragraph boundaries with ~500-token targets. For README-heavy repos with lots of code blocks, would a structure-aware splitter (respecting markdown headings and code fences) meaningfully improve retrieval?
3. RAG scope: I deliberately restricted RAG to the user's knowledge base rather than all stars. For those who've built RAG products, does a narrower but higher-trust data scope lead to better user outcomes than broader but noisier retrieval?

Happy to answer implementation questions. The app is downloadable at https://starcat.ink.
