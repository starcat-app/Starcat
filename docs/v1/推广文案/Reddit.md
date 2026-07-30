# Reddit

> 平台定位：短、口语、I built X because…；求反馈，不要落地页文案。
> 配图：2 张够；可直接传 Reddit，或用知乎 CDN 直链。

---

## 注册与发帖清单（发前必读）

### 怎么注册

1. 打开 https://www.reddit.com → **Sign Up**
2. 邮箱 / Google / Apple 均可
3. 用户名公开且难改，建议和 PH / GitHub 一致（如 `dong4j`）
4. 头像 + 短 bio 可选，但有助于不像营销号

### Reddit 特有门槛

| 点 | 说明 |
|---|---|
| 无全站统一 karma 门槛 | **每个 sub 自设**；AutoMod 常静默吞帖，看起来像发出去了其实没曝光 |
| 养号 | 先评论、后发帖；建议 **1–2 周** 真实参与目标 sub |
| 自推比例 | 多评论少发帖；账号不要只发自己的产品 |
| 同帖多发 | **不要同一天**把同一链接刷进多个 sub；错开几天，文案按受众微调 |
| 刷赞 / 多号 | 禁止；易影子封禁 |
| 发帖前 | 打开目标 sub → **About / Rules / 置顶**（规则常变，以线上为准） |

规则入口（发前再点一次）：

- https://www.reddit.com/r/SideProject/about/rules
- https://www.reddit.com/r/macapps/about/rules

### 建议发帖顺序

| 顺序 | Sub | 注意 |
|---|---|---|
| 1 | `r/SideProject` | 对「我做的项目求反馈」最友好 |
| 2 | `r/macapps` | 强调 native / 非 Electron；发前读 sidebar |
| 3 | `r/indiehackers` | 偏 maker 叙事 |
| 4 | `r/github` | 偏工具 / Stars 工作流 |
| 慎发 | `r/programming` | 只适合偏技术长文；纯产品帖易沉或被删 |

### 发帖实操

1. 养号期：在目标 sub 认真回 5～10 条（mac 工具、indie、GitHub 工作流）
2. 正文用求反馈语气；链接放文末
3. 图可直接上传 Reddit（更稳）或 CDN 直链
4. 发完盯评论，逐条回；不要 post-and-ghost
5. 没水花别隔两天重发；等有实质更新再发第二帖

### 改稿原则（相对旧稿）

- 旧稿几乎没写 RAG → 必须补上（当前主卖点）
- Stars 数字对齐截图：`1,800+`
- 功能列表收短；RAG 单独一段
- 配图 2 张：管理 + RAG
- 结尾必须带具体问题
- 按 sub 微调标题；正文可共用，勿原样同步刷多个 sub

---

## Suggested Subreddits

- `r/SideProject`（优先）
- `r/macapps`
- `r/indiehackers`
- `r/github`
- `r/programming` only if the post is technical

## Title Options

### Default (SideProject / general)

Looking for feedback: Starcat — local GitHub Stars knowledge base + RAG (macOS)

### Alternatives

- My GitHub Stars became a graveyard, so I built a local-first macOS app
- I built a native macOS app to organize GitHub Stars and ask them questions

### r/macapps tweak

Looking for feedback: Starcat — native (non-Electron) macOS app for GitHub Stars + local RAG

## Post Draft

I built a macOS app called Starcat because my GitHub Stars stopped being useful.

I have 1,800+ starred repos. Some were tools I wanted to try, some were libraries I used once, some were AI projects I wanted to follow, and a lot were just "I'll read this later." GitHub's Stars page is fine for bookmarking, but it's not great when you want to search, organize, revisit, and compare repos over time. I once spent ~20 minutes scrolling for a Swift clipboard manager I'd starred months earlier — I couldn't remember the name.

Starcat syncs Stars locally into a more research-oriented workspace:

- native three-column macOS UI (SwiftUI, not Electron)
- local README cache/reader
- tags, notes, reading status
- full-text + semantic search
- release tracking, Trending/Weekly, similar-repo recommendations
- AI summaries / tag suggestions / translation / in-repo chat (suggestions need manual confirm)

Screenshots:

- Manage view: https://cdn.dong4j.site/source/image/zhihu-01-manage.webp
- RAG workbench: https://cdn.dong4j.site/source/image/zhihu-04-rag-qa.webp

**The part I care about most right now is Knowledge Base RAG (v1.1).**

Sometimes you don't need "find a repo" — you need an answer. Example: "which of my saved SwiftUI projects use Core Data?" That's not a keyword search. Starcat runs local hybrid retrieval (FTS5 + local embeddings, vDSP-accelerated) over your **knowledge base** (repos you actively add to your library — not all stars), then returns a citation-backed answer. RAG is read-only; it doesn't auto-write tags or notes. AI calls use your own provider (BYOK / Ollama / etc.), and the index stays on your Mac by default.

There's also a local MCP service + CLI so Claude/Codex/other agents can query the same library.

**Exploring next (not all shipped):** batch organize / merge labels, alternative-finding & selection reports, weekly digests + "what was that SSR framework I starred last year?" memory search.

I'd love feedback from people who use GitHub Stars heavily:

1. How do you organize Stars today (or do you just… not)?
2. Should RAG stay strict to the knowledge-base subset, or offer an "search all stars" option?
3. For a single-user macOS app with tens of thousands of chunks, is local vector scan (vDSP) enough, or would you expect an embedded vector DB?

Site: https://starcat.ink  
Code: https://github.com/starcat-app (issues: `starcat-app/starcat-pro`)
