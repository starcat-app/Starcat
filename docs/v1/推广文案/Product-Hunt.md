# Product Hunt

> 平台定位：一句话价值 + 视觉 + Maker 人设故事；不要写成 HN 架构长文。
> 配图：复用知乎 CDN；上传 Gallery 时用 webp/png 均可，caption 见下。

---

## 注册与发帖清单（发前必读）

### 怎么注册

1. 打开 https://www.producthunt.com → 右上角 **Sign up**
2. 可用邮箱 / Google / X 等登录
3. **必须用个人账号**；禁止公司 / 品牌号发帖或评论
4. 完善资料（影响信任）：
   - 真人头像（不要 Logo / 纯 AI 头）
   - 短 bio（像人，不像 slogan）
   - 可挂官网、X、GitHub

准备页：https://www.producthunt.com/launch/before-launch

### 发帖门槛与节奏

| 点 | 说明 |
|---|---|
| 新号发帖 | 需完成 onboarding；官方通常要求新账号约 **等 1 周** 才能 post |
| 养号 | 建议至少提前 **1–4 周**（更好更早）：upvote + 认真评论，别只在 launch 当天出现 |
| Hunter | 自己 hunt 即可，不必找大 V hunter |
| 上线时间 | 按 **PST 日切**：选定日 **12:01 AM PST** 上线（北京时间约当天 15:01 / 16:01，看夏令时） |
| 推荐日 | 常见建议：**周二～周四**；周末流量通常更差 |
| 可预约 | 可 schedule（约提前一个月内）或先 **Create draft** |
| 刷票 | 冷号互赞、当天新号刷 upvote 易被降权 / 清票；支持者应**提前养号** |

发帖入口：登录 → **Post** → 填产品 URL → 预览各区块 → 添加 Maker（填自己的 PH username）→ Schedule / Draft。

官方：https://help.producthunt.com/en/articles/479557-how-to-post-a-product

### Launch 日注意

1. 官网、下载、截图、tagline 全部先就绪
2. Maker Comment 准备好，上线后尽快贴成首评
3. 通知真实用户时个人化，**别组织刷票**
4. 全天在线回评论（PH 很吃 maker 互动）
5. X / 邮件可带 PH 链接；Launch Tweet 见文末

### 改稿原则（相对旧稿）

- Tagline 短、可感；偏 hook 而非说明书
- Short Description 压到约 2 句
- Gallery 用 CDN 新图 + 明确 caption；默认 4 张
- Maker Comment：故事保留，「今天能做什么」收短；RAG 一段保留；MCP 两三句；路线标 exploring
- Stars 数字与截图对齐：`1,800+`
- Launch Tweet 压到可直接发的长度

---

## Product Name

Starcat

## Tagline

Ask your GitHub Stars — local RAG on native macOS

### Alternatives

- Turn GitHub Stars into a local-first, queryable knowledge base
- Turn GitHub Stars into a local-first knowledge base you can ask questions to

## Short Description

Starcat is a native macOS app that turns GitHub Stars into a local-first knowledge base. Sync and organize repos on your Mac, then ask cross-repo questions with citation-backed RAG — without uploading your library to a SaaS backend.

## Gallery Notes

Upload these (CDN sources; download then upload to PH if the form needs local files):

1. https://cdn.dong4j.site/source/image/zhihu-01-manage.webp  
   Caption: Your Stars, organized in a native macOS workspace.
2. https://cdn.dong4j.site/source/image/zhihu-02-repo-detail.webp  
   Caption: READMEs, notes, and tags in one place.
3. https://cdn.dong4j.site/source/image/zhihu-03-ai-suggest.webp  
   Caption: AI that suggests — you confirm before it writes.
4. https://cdn.dong4j.site/source/image/zhihu-04-rag-qa.webp  
   Caption: Cross-repo RAG with citations (knowledge base only).

Optional 5th: https://cdn.dong4j.site/source/image/zhihu-05-rag-citation.webp  
Caption: Every answer links back to the source paragraph.

## Maker Comment

Hi Product Hunt,

I'm dong4j. A year ago, I realized my GitHub Stars had become useless.

Not because GitHub is bad — but because starring is too easy. Click, and it's saved. After a few years I had 1,800+ starred repos and no way to find the one I actually needed. I once spent 20 minutes scrolling, trying to remember the name of a Swift clipboard manager I'd starred months earlier.

So I built Starcat: a native macOS app (SwiftUI, not Electron) that treats your GitHub Stars as a personal map of tools, libraries, and ideas worth remembering.

**What it does today:**

- Sync Stars into a native three-column workspace; cache & read READMEs offline
- Tags, notes, reading status, full-text (FTS5) + semantic search
- AI summaries, tag suggestions, translation, and in-repo chat (suggestions need your confirm)
- Release tracking, Trending/Weekly feeds, similar-repo recommendations

**The part I'm most excited about — Knowledge Base RAG (v1.1.0):**

A dedicated workspace for natural-language questions across your **knowledge base** (repos you actively add to your library — not all stars). Example: "which of my saved SwiftUI projects use Core Data?" That's not a keyword search; it needs semantic retrieval across READMEs, notes, and summaries, then a citation-backed answer.

Retrieval is local-first hybrid: FTS5 + local vector search (vDSP-accelerated, ~23x vs naive Swift), optional remote reranker. RAG is **read-only** — it never auto-writes tags or notes.

**AI toolchain:** local MCP Service + `starcat-cli` so Claude/Codex/other agents can query your stars and pull structured repo context. You bring your own AI provider (OpenAI-compatible, DeepSeek, OpenRouter, Ollama, …). Data stays on your Mac by default.

**Exploring next (not all shipped):** Organize (batch-tag, merge labels) · Discover (alternatives, selection reports) · Digest (weekly digests, memory search).

Open source under [github.com/starcat-app](https://github.com/starcat-app); issues at `starcat-app/starcat-pro`.

Would love feedback from anyone with a large Stars library, people doing open-source research, or folks building local RAG on macOS.

Website: https://starcat.ink

## Launch Tweet

I launched Starcat on Product Hunt: a native macOS app that turns GitHub Stars into a local-first knowledge base you can ask questions to.

Local sync + tags/notes · cross-repo RAG with citations · MCP for your AI toolchain · BYOK

Built for developers whose Stars became "I'll look at it later."

[PH link]
https://starcat.ink
