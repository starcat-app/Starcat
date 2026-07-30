# Hacker News / Show HN

> 平台定位：技术、tradeoff、诚实区分 done vs planned；不要 launch-copy。
> 配图：复用知乎 CDN；HN 文本区对 Markdown 图支持不稳定，正文用直链更稳。

---

## 注册与发帖清单（发前必读）

### 怎么注册

1. 打开 https://news.ycombinator.com/login
2. 页面下半部分 **Create Account**：填 `username` + `password`
3. 经典 HN **不强制邮箱**——密码务必自己保管，丢失很难恢复
4. 可能出现 reCAPTCHA：用人手浏览器完成，不要用脚本/自动化注册

| 情况 | 处理 |
|---|---|
| `Sorry, account creation disabled` | 站方临时关闭注册，换时段再试 |
| 只有 Login 看不到 Create | 刷新或直开 `/login`；偶发限流 |
| 新号发帖受限 | 新号可 submit，但有频率限制；先逛/认真评论几天更稳 |
| 求好友 upvote / 刷赞 | **禁止**，违反 HN 规范 |

### 发 Show HN 前建议

1. 账号先养几天：看帖、认真回几条评论（别灌水）
2. 产品必须**别人能试用**：有 https://starcat.ink 下载即可；不要只丢 landing / 募资页
3. 标题必须以 **`Show HN:`** 开头
4. 发帖路径：登录 → 顶部 **submit** → Title + URL（可挂官网）+ text（正文）
5. 发完盯评论区，本人要在线答技术问题
6. 官方指南：https://news.ycombinator.com/showhn.html  
   Show HN 适合「可试用的东西」；小版本升级一般不够格，大改（如 Hybrid RAG）可以

### 改稿原则（相对旧稿）

- Stars 数字与截图对齐：用 `1,800+` / `~1,900`，不要虚高 `2,000+`
- 配图 2 张够：管理主视图 + RAG 问答；正文用 URL 直链，不依赖 Markdown 图渲染
- 标题略收，突出 local Hybrid RAG + macOS
- 「Other details」压成短 bullet，少列服务名
- 「What next」每条一句话，标明 exploring
- 正文开头写清试用门槛：macOS 15+ / Apple Silicon（若适用）

---

## Positioning

HN users usually dislike launch-copy. Be specific, technical, and honest about what is done versus planned. Focus on architecture decisions, tradeoffs, and implementation details rather than product pitch.

## Title

Show HN: Starcat – local Hybrid RAG over your GitHub Stars (native macOS)

### Alternatives

- Show HN: Starcat — a native macOS app with local Hybrid RAG for GitHub Stars research
- Show HN: Starcat – turn GitHub Stars into a local-first, queryable knowledge base (macOS)

## Post Draft

Hi HN,

I built Starcat because my GitHub Stars turned into a graveyard of "I'll look at this later." After 1,800+ stars, I couldn't find repos I knew I had saved, couldn't remember why I starred them, and couldn't answer simple questions like "which of my saved projects use Core Data?"

Starcat is a native macOS app (SwiftUI, SQLite/GRDB, local embedding + vDSP vector search) that syncs your GitHub Stars locally and turns them into a searchable, queryable knowledge base. The thing I want to show today is the local Hybrid RAG pipeline shipped in v1.1.0.

**Try it:** https://starcat.ink — requires macOS 15+ (Apple Silicon recommended). No account wall beyond GitHub OAuth for stars sync.

Screenshots (direct links; HN text may not render Markdown images):

- Manage view: https://cdn.dong4j.site/source/image/zhihu-01-manage.webp
- RAG workbench: https://cdn.dong4j.site/source/image/zhihu-04-rag-qa.webp

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

- Native macOS (SwiftUI + GRDB + WKWebView), not Electron; three-column layout.
- Similar-repo recommendations go through a small `starcat-recommend-api` boundary so the client stays on a stable API while the backend can swap engines.
- Local MCP Service + Go CLI (`starcat-cli`) let Claude/Codex/other agents query stars and pull structured repo context.
- App + supporting services live under [github.com/starcat-app](https://github.com/starcat-app); issues at `starcat-app/starcat-pro`.

### What I'm exploring next

Not a generic chatbot — three workflow lines, all **exploring / not fully shipped**:

- **Organize**: batch-tag untagged stars, merge near-duplicate labels, scan abandoned/overlapping clusters.
- **Discover**: alternative-finding and tech-selection agents with citation-backed comparison tables.
- **Digest**: weekly star digests, release upgrade notes with breaking-change emphasis, memory search ("that SSR framework I starred last year").

### Questions for HN

1. Local vs. server-side vector DB: for a single-user macOS app with ~10k-50k chunks, is the vDSP approach sustainable, or should I plan for a local vector DB (Qdrant/Milvus embedded) at a certain scale?
2. Chunk strategy: I'm currently splitting on paragraph boundaries with ~500-token targets. For README-heavy repos with lots of code blocks, would a structure-aware splitter (respecting markdown headings and code fences) meaningfully improve retrieval?
3. RAG scope: I deliberately restricted RAG to the user's knowledge base rather than all stars. For those who've built RAG products, does a narrower but higher-trust data scope lead to better user outcomes than broader but noisier retrieval?

Happy to answer implementation questions. Download: https://starcat.ink
