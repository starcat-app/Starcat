# X / Twitter

> 平台定位：短 thread + 截图；hook → 痛点 → 产品 → RAG → CTA。
> 账号已有；发帖用免费号 280 字/条即可。配图复用知乎 CDN。

---

## 发帖清单（发前必读）

### Bio（若未改）

```
Indie maker · Starcat — local-first GitHub Stars knowledge base for macOS
https://starcat.ink
```

### 注意

| 点 | 说明 |
|---|---|
| 形态 | Thread **5～8 条**；可另发一条 Short Post |
| 链接 | **放最后一条**；前面靠截图拉停留 |
| 标签 | 少用；最多 1 个 `#buildinpublic` |
| 时间 | 工作日上午或傍晚（按粉丝活跃调） |
| 互动 | 发后 1～2 小时盯回复；相关帖认真回，别 spam 贴链 |
| PH / HN | PH 当天 CTA 可换 PH 链接；HN 暂缓则挂 starcat.ink |
| 别做 | 刷量互关、同文连发、纯 Please RT |

### 改稿原则

- 旧稿缺 RAG → 必须写进 thread 中段
- Stars 用 `1,800+`
- 配图 2～3 张 CDN；末条必须有 CTA
- 与 `Product-Hunt.md` Launch Tweet 分开：本文件偏日常 / soft launch

---

## Thread Draft

**1/**  
I built Starcat because my GitHub Stars turned into "I'll look at this later."

1,800+ starred repos. Native macOS. Local-first knowledge base you can actually ask questions to.

**2/**  
The problem isn't bookmarking.

After hundreds of stars you can't answer:

- Why did I star this?
- Is it still maintained?
- What did I use before for X?
- Which of my saved projects use Core Data?

**3/**  
Starcat syncs Stars onto your Mac:

- three-column native UI (SwiftUI, not Electron)
- local README cache
- tags / notes / reading status
- full-text + semantic search
- releases, Trending/Weekly, similar-repo picks

https://cdn.dong4j.site/source/image/zhihu-01-manage.webp

**4/**  
The part I care about most: Knowledge Base RAG (v1.1).

Ask: "which of my saved SwiftUI projects use Core Data?"

Local hybrid retrieval (FTS5 + embeddings, vDSP-accelerated) over repos you add to your library — not all stars. Answers come with citations. RAG is read-only.

https://cdn.dong4j.site/source/image/zhihu-04-rag-qa.webp

**5/**  
AI isn't the main character. Context is.

Summaries, tag suggestions, translation, in-repo chat — suggestions need your confirm before write. BYOK / Ollama. Data stays on your Mac by default.

https://cdn.dong4j.site/source/image/zhihu-03-ai-suggest.webp

**6/**  
Exploring next (not all shipped):

Organize → clean messy stars / merge labels  
Discover → alternatives & selection reports  
Digest → weekly digests + "what was that SSR framework I starred last year?"

Also: local MCP + CLI so Claude/Codex can query the same library.

**7/**  
If your Stars became a graveyard, try Starcat:

https://starcat.ink  
Code: https://github.com/starcat-app

Feedback welcome — especially on the RAG knowledge-base boundary vs searching all stars.

---

## Short Post

I built Starcat: a native macOS app that turns GitHub Stars into a local-first knowledge base.

Sync + organize on your Mac. Ask cross-repo questions with citation-backed RAG. BYOK. Not Electron.

https://starcat.ink

---

## PH Launch Day (optional one-liner)

I launched Starcat on Product Hunt — local-first GitHub Stars knowledge base + RAG for macOS.

[PH link]  
https://starcat.ink
