# 回忆搜索 Agent 方案（消化线）

> **文档定位**：用户用 **自然语言** 提问，Agent 在 **已 star 仓库**（及 notes / README 缓存）中检索，输出 **带引用的答案**——不是 repo 列表，而是「我得到一个回答」。
> **产品叙事**：[`10-Agent产品叙事-三条主线.md`](10-Agent产品叙事-三条主线.md) · **消化线**
> **状态**：方案稿（2026-06-27），等 dong4j 拍板立项。
> **与 RAG 文档关系**：本方案是 [`30-本地RAG设计.md`](../详细设计/30-本地RAG设计.md) 的 **Agent 化 MVP**（检索层复用现有 FTS + semantic；生成层走 Agent loop + 引用约束）。
> **关联文档**：
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)：共用 `AgentOrchestrator`
> - [`04-AgentRunKit-Swarm-SwiftAgent-对比分析.md`](04-AgentRunKit-Swarm-SwiftAgent-对比分析.md)
> - [`../详细设计/29-关键词与全文检索设计.md`](../详细设计/29-关键词与全文检索设计.md)
> - [`../详细设计/26-向量搜索改进.md`](../详细设计/26-向量搜索改进.md)

---

## 一、用户故事

### 1.1 主流程

> 作为 Starcat 用户，我在 **搜索中心** 或 **Agent → 消化 → 回忆搜索** 输入：
>
> 「我去年 star 的那个做 edge SSR 的框架是哪个？」
>
> Agent：
> 1. 理解意图（时间范围 + 技术主题 + 「找一个」）
> 2. 调 FTS + semantic + starredAt 过滤召回候选
> 3. 读 top 候选的 description / note / README 片段
> 4. 回答：「最可能是 **fresh**（2025-08 star，note 里提到 edge function）。其次是 sveltekit…」并附 **可点击引用**

### 1.2 更多典型问句

| 用户问题 | 期望答案形态 |
|----------|--------------|
| 「我 star 过哪些向量数据库项目？分别什么定位？」 | 3~5 个 repo + 各一句定位 + 引用 |
| 「react 状态管理我收藏了哪些方案？」 | 列表式回答 + 对比一句 |
| 「grpc-gateway 在我笔记里写过什么？」 | 引用 note 原文片段 |
| 「macOS 工具里哪个和 Liquid Glass 有关？」 | 综合 README + topics + note |
| 「什么是 React Hooks？」 | **拒答或降级**：「这不在你的 stars 库内，请用通用 AI」 |

### 1.3 与现有搜索的差异

| 维度 | Search Center 关键词/semantic | **回忆搜索 Agent** |
|------|------------------------------|-------------------|
| 输入 | 关键词 / 短句 | 完整自然语言问句 |
| 输出 | repo 列表 + 分数 | **自然语言答案** + 引用 chip |
| 模型 | 0~1 次 embedding | 1 次 embedding + **1~3 次 LLM**（含 optional 多步 tool） |
| 时延 | ms~2s | 5~20s（streaming） |
| 心智 | 「找列表自己读」 | 「直接告诉我答案」 |

---

## 二、核心价值

> **「让 1800+ stars 从收藏夹变成可问答的记忆」**——竞品只有搜索框，没有「答」。

**核心差异化**：

1. **知识源边界**：只答 stars 库 (+ 用户 notes)，不装成 ChatGPT；
2. **个人上下文**：starredAt、status、note 参与排序与答案；
3. **引用可验证**：每个主张挂 `owner/repo` 或 note 片段，可点进详情。

---

## 三、架构：Retrieve →（Optional Rerank）→ Generate

### 3.1 MVP 与 30 文档的裁剪

| 30 文档完整 RAG | 本方案 MVP | 延后 |
|-----------------|------------|------|
| chunk-level 向量 | **repo-level** semantic（已有） | chunk 索引 |
| cross-encoder rerank | LLM 轻量 rerank（单 prompt） | 专用 rerank 模型 |
| 多轮对话记忆 | 单 session 内 history（最多 6 轮） | 长期 memory |
| 答案缓存表 | 可选 `recall_search_cache` | v1.1 |

### 3.2 数据流

```text
用户问句
  │
  ├─ Tool: parse_recall_intent（可选 LLM 或规则）
  │     → { keywords[], timeRange?, statusFilter?, wantsNote? }
  │
  ├─ 并行召回
  │     ├─ search_starred_fts(keywords)
  │     ├─ search_starred_semantic(query)
  │     └─ filter_by_starred_at / status / tag（若有）
  │
  ├─ merge_candidates（RRF 或加权：semantic 0.6 + FTS 0.4）
  │
  ├─ Tool: fetch_evidence_chunks(repoIds top 8)
  │     → description + note + readme 前 400 token + AI summary 若有
  │
  ├─ Tool: rerank_candidates（LLM 或规则：note 命中 +using 加权）
  │
  └─ Tool: generate_answer_with_citations
        → streaming Markdown + Citation[]{ repoId, snippet, source: note|readme|meta }
```

---

## 四、工具集

### 4.1 工具清单

```
Tool 1: parse_recall_intent
  输入:  userQuestion(String)
  输出:  RecallIntent { keywords[], starredAfter?, starredBefore?,
          statusIn?, tag?, answerStyle: single|list|compare }
  内部:  MVP 可用规则+关键词；v1.1 用小模型 LLM
  约束:  解析结果必须 JSON；禁止把 userQuestion 原文注入 system prompt

Tool 2: search_starred_fts
  输入:  query, limit(默认 30)
  输出:  repoId[], bm25Score[]
  复用:  RepoRepository.searchFTS（含 notes_fts 联合）

Tool 3: search_starred_semantic
  输入:  query, limit(默认 30), minDisplayScore?(默认 0.45)
  输出:  repoId[], displayScore[], tier[]
  复用:  SemanticSearchService.search + StarcatMCPFacade.semanticSearch 同款

Tool 4: filter_starred_repos
  输入:  repoIds[], starredAfter?, starredBefore?, status?, tag?, language?
  输出:  filteredIds[]
  复用:  GRDB 查询 / SmartCollection 条件子集

Tool 5: fetch_evidence_for_repos
  输入:  repoIds[] (max 8)
  输出:  Evidence[] { repoId, fullName, description, noteExcerpt?, readmeExcerpt?,
          summaryOneLiner?, starredAt, status }
  复用:  ReadmeRepository / RepoNoteRepository / AISummaryRepository
  约束:  每 repo 总 evidence ≤ 600 tokens

Tool 6: merge_and_rank_candidates
  输入:  ftsHits[], semanticHits[], intent
  输出:  rankedRepoIds[] (max 10)
  内部:  **纯 Swift** RRF；note 字面命中 +0.2；status=using +0.1

Tool 7: generate_recall_answer
  输入:  userQuestion, evidence[], rankedRepoIds[]
  输出:  streaming Markdown + citations[]
  内部:  LLM；prompt 强制「仅基于 evidence；无 evidence 则说不知道」
  约束:  必须含 [[owner/repo]] 或 `[note:owner/repo]` 引用格式
```

### 4.2 拒答与降级策略

| 条件 | 行为 |
|------|------|
| 召回 0 候选 | 「你的 stars 里没有找到相关项目」+ 建议改写 |
| 召回有但 evidence 弱 | 列出 top 3 repo **列表降级**，并说明「无法确定唯一答案」 |
| 问句与 stars 无关（通用知识） | 固定拒答模板 + 链到外部 AI 设置 |
| semantic 未索引 | 降级仅 FTS + metadata；UI 提示开启语义索引 |

---

## 五、Agent 编排循环

### 5.1 标准路径（5~6 步）

```
[Step 1] system: 回忆搜索助手；仅 stars 库；必须引用；禁止编造
[Step 2] user: 「我去年 star 的 edge SSR 框架是哪个？」
[Step 3] tool: parse_recall_intent
         → keywords: [edge, SSR], starredAfter: 2025-01-01
[Step 4] parallel tools: search_starred_fts + search_starred_semantic
[Step 5] tool: filter_starred_repos + merge_and_rank_candidates
[Step 6] tool: fetch_evidence_for_repos (top 5)
[Step 7] tool: generate_recall_answer → stream to UI
[Step 8] final_answer（含 citations 结构化 payload）
```

**maxSteps = 8**；多数问句 **不** 需要 LLM 自主追加 tool（防 runaway）。

### 5.2 多轮追问

```
user: 「fresh 和 sveltekit 我 notes 里分别怎么写的？」
→ 继承 session rankedRepoIds + 直接 fetch_evidence（fresh, sveltekit）
→ generate_recall_answer（history 最多 6 轮）
```

---

## 六、UI 落地

### 6.1 入口

| 入口 | 说明 |
|------|------|
| **搜索中心** | 模式切换：`搜索` / `回忆`（问句 icon） |
| **Agent → 消化 → 回忆搜索** | 独立对话页，带示例问句 chip |
| **Sidebar 快捷** | ⌘K 打开搜索中心并默认回忆模式（可选） |

### 6.2 回答区 UI

```
┌─ 回忆搜索 ──────────────────────────────────────────────┐
│  🔍 我去年 star 的 edge SSR 框架是哪个？                  │
│                                                          │
│  ┌─ 回答（streaming）────────────────────────────────┐  │
│  │  根据你的 stars 与笔记，**最可能是 fresh** …        │  │
│  │  [[denoland/fresh]]  [[sveltejs/kit]]               │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  引用来源                                                │
│  ┌─ denoland/fresh ── note ──────────────────────────┐  │
│  │  「edge function 部署很方便…」                      │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌─ denoland/fresh ── meta ── starred 2025-08-12 ───┐  │
│                                                          │
│  [在列表中查看] [复制回答] [反馈不准]                     │
└──────────────────────────────────────────────────────────┘
```

### 6.3 引用交互

- 点击 `[[owner/repo]]` → 打开 repo detail（现有导航）；
- `[note:…]` → detail 并 scroll 到 note 区；
- **禁止**无引用裸断言（Generator prompt + 客户端校验 citations 非空）。

### 6.4 与 Search Center 共存

- **搜索模式**：保持现有 Provider 编排（local / github / web）；
- **回忆模式**：隐藏 github/web scope，底部文案：「仅在已 star 仓库中回答」；
- 同一搜索框 **根据模式** 路由到 `SearchCoordinator` vs `RecallSearchAgent`。

---

## 七、数据闭环

### 7.1 复用 Starcat 已有

| 模块 | 用途 |
|------|------|
| `RepoRepository.searchFTS` | FTS 召回（含 notes） |
| `SemanticSearchService` | 语义召回 |
| `StarcatMCPFacade.semanticSearch` | Tool 实现可委托 |
| `ReadmeRepository` | README 片段 |
| `RepoNoteRepository` | note 证据 |
| `AISummaryRepository` | one_liner / summary |
| `RepoAIWindowContentView` 流式 | 回答 streaming |
| `SearchHistoryRepository` | 可选：回忆问句历史 |

### 7.2 新增 `recall_search_sessions` 表（可选，MVP 可仅内存）

```sql
CREATE TABLE recall_search_sessions (
    id TEXT PRIMARY KEY,                      -- UUID
    title TEXT,                               -- 首问句截断
    messages_json TEXT NOT NULL,              -- 多轮 transcript（不含 tool raw）
    last_citations_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

**MVP 取舍**：可先 **仅会话内内存** + 「复制回答」；持久化放 v1.1。

### 7.3 可选 `recall_answer_cache`

```sql
CREATE TABLE recall_answer_cache (
    query_hash TEXT PRIMARY KEY,              -- normalize(question)+indexVersion
    answer_markdown TEXT NOT NULL,
    citations_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    ttl_expires_at TEXT NOT NULL
);
```

- `indexVersion` = embedding model + 最大 repo_embeddings.updated_at；
- TTL 24h；用户改 note 后 indexVersion 变 → cache miss。

---

## 八、付费与配额

| 档 | 体验 |
|----|------|
| **Free** | 每月 **15 次**回忆问句；仅 repo-level 证据；无多轮（单轮 only） |
| **Pro** | 不限次数；多轮追问；note+readme 深证据；导出回答 |

**Quota**：

- 检索 tools（FTS/semantic/filter）：**0 LLM quota**；
- `parse_recall_intent`（若走 LLM）：0.5 → 1 次计 1 quota；
- `generate_recall_answer`：**1 quota**；
- 单次完整问句 **≈ 1~2 quota**。

---

## 九、Prompt 与引用规范（摘要）

### 9.1 System 约束（要点）

- 只使用 tool 返回的 evidence；
- 无足够 evidence 时明确说「无法从你的 stars 确认」；
- 每个结论至少一个 `[[owner/repo]]` 引用；
- 不推荐用户 star 新项目（发现线职责）；
- 中文问句 → 中文回答（遵循 App locale）。

### 9.2 引用格式（解析器单一信任源）

```markdown
根据你的收藏，[[denoland/fresh]] 最符合「edge SSR」…
你在 [note:denoland/fresh] 里写到：「edge function…」
```

客户端 regex 解析 → `Citation` model → chip UI。

---

## 十、工作量估算

| 模块 | 类型 | 估算 |
|------|------|------|
| 7 个 Tool（多数薄包装） | 新增 | 中 |
| RRF merge + intent 规则 | 新增 | 小 |
| `generate_recall_answer` prompt + citation 解析 | 新增 | 中 |
| 搜索中心「回忆模式」切换 + UI | 新增 | 中 |
| Agent 消化 Tab 对话页 | 新增 | 小（复用 AI 窗口） |
| 单测（merge / 拒答 / citation parse） | 新增 | 中 |
| i18n `agent.digest.recall.*` | 新增 | 小 |

**总估时**：**中**（与 30 文档 chunk RAG 比，MVP 范围可控）。

---

## 十一、关键风险与缓解

| 风险 | 等级 | 缓解 |
|------|------|------|
| LLM 幻觉 repo 名 | **致命** | evidence-only prompt；citations 必须在 rankedIds 内 |
| 语义索引未建全 | 高 | 降级 FTS；设置页引导 |
| 慢（>20s） | 中 | 并行召回；evidence 预取 top 5；streaming 首 token |
| 与 Search Center 心智混淆 | 中 | 模式切换明确文案；回忆模式禁用 github/web |
| 私仓 note 进 LLM | 中 | 设置「回忆搜索包含 private notes」开关，默认开 |
| 多轮 context 爆炸 | 中 | history 最多 6 轮；evidence 不重复塞全文 |

---

## 十二、演进路线（对齐 30 文档）

| 版本 | 能力 |
|------|------|
| **MVP（本文）** | repo-level FTS + semantic + note/readme 截断 + 引用回答 |
| **v1.1** | 会话持久化 + answer cache + 多轮 |
| **v1.2** | README chunk 向量（30 文档 D 方案） |
| **v1.3** | rerank 专用模型 / FM 本地 rerank（macOS 26 门控） |

---

## 十三、变更记录

| 日期 | 变更 | 作者 |
|------|------|------|
| 2026-06-27 | 初稿 | Claude |
