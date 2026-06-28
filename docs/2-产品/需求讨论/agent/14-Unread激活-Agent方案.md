# Unread 激活 Agent 方案（消化线）

> **文档定位**：从 **unread / implicit unread** 库存中，按优先级挑出「**现在值得看**」的 repo，给出 **理由 + 行动建议**（阅读 / 标 using / 打 tag）；不自动改 status。
> **产品叙事**：[`10-Agent产品叙事-三条主线.md`](10-Agent产品叙事-三条主线.md) · **消化线**
> **状态**：方案稿（2026-06-27），等 dong4j 拍板立项。
> **关联文档**：
> - [`03-Starred-Repo-周报-Agent方案.md`](03-Starred-Repo-周报-Agent方案.md)：周报讲 **新增** stars；本方案讲 **积压 unread**
> - [`12-回忆搜索-Agent方案.md`](12-回忆搜索-Agent方案.md)：用户 **主动问**；本方案 **主动推荐**
> - [`11-重叠扫描-Agent方案.md`](11-重叠扫描-Agent方案.md)：整理线；unread 过多时可先整理再激活

---

## 一、用户故事

### 1.1 主流程

> 作为 Starcat 用户，打开 Starcat 时 **Agent → 消化 → 今日激活**，看到：
>
> **「本周建议先读这 5 个」**
>
> 每个卡片含：
> - 为什么现在（Release 刚发版 / 你 star 后从未打开 / 与你在 using 的 X 同类）
> - 预计阅读时间（README 长度粗估）
> - [打开 README] [标为 using] [稍后提醒]

### 1.2 触发模型

| 触发 | 说明 | MVP |
|------|------|-----|
| **打开 App** | Home 空态 / 消化 Tab 卡片 | 🥇 |
| **手动** | 「刷新推荐」按钮 | 🥇 |
| **Sidebar Unread 过滤器** | 顶部「AI 帮我挑 5 个」 | 🥇 |
| **每周一 push** | `NSBackgroundActivityScheduler` | 🥈 v1.1 |
| **Release 订阅事件** | 订阅 repo 发 major → 插入激活列表 | 🥈 |

### 1.3 与 03 周报、12 回忆搜索的差异

| 维度 | 03 周报 | 12 回忆搜索 | **14 Unread 激活** |
|------|---------|-------------|---------------------|
| 对象 | 本周 **新 star** | 全库问答 | **unread 积压** |
| 交互 | 被动阅读报告 | 用户提问 | **主动推送清单** |
| 输出 | 聚类周报 | 自然语言答案 | **Top N 卡片 + 理由** |
| 目标 | 兴趣画像 | 找回记忆 | **促进行动（读/用）** |

---

## 二、核心价值

> **「把 unread 从 guilt 变成可执行的短清单」**——1810 stars 里 70% unread 是真实痛点。

**核心差异化**：

1. **信号融合**：starredAt + last open（若有）+ Release + health + 与 `using` repo 的语义近邻；
2. **可行动**：每条推荐绑具体 CTA，不是纯文字；
3. **尊重状态**：`using` 已在读的不重复推；用户 dismiss 的 repo 进入冷却。

---

## 三、优先级模型（Scoring）

### 3.1 候选池

```text
候选 = { repo | status == unread 或 statusMap 缺失（implicit unread）}
        ∩ is_starred
        ∩ ¬isArchived（可选包含 archived 低优桶）
        - 用户 dismiss 冷却期内（默认 14 天）
        - 已在本次 Top N 出现过且用户 marked read 7 天内
```

### 3.2 分数构成（0~100，纯 Swift 可单测）

| 信号 | 权重 | 说明 |
|------|------|------|
| **Release 7 日内** | +25 | 订阅 repo 有新 release |
| **star 后从未打开 README** | +15 | `ReadmeViewModel` 无缓存命中记录（v1.1 精确；MVP 用 note 空 + status unread） |
| **starredAt 30~180 天前** | +10 | 太新不急，太老降权 |
| **semantic 近 using** | +20 | 与用户 `using` repo 平均向量相似度 top 10% |
| **Repo health 良好** | +10 | 非 archived、近期 push |
| **有 AI summary 缓存** | +5 | 降低阅读成本 |
| **OpenSSF / health 告警** | -15 | 低优，除非用户显式「安全关注」 |
| **重复主题已 using 同类** | -10 | 避免推第五个状态库 |

### 3.3 LLM 的角色（可选层）

- **MVP**：分数排序 top 15 → LLM **只写理由文案**（每 repo ≤ 2 句），不重排；
- **v1.1**：LLM rerank top 15 → 5，结合用户 note 个性化理由。

---

## 四、工具集

### 4.1 工具清单

```
Tool 1: list_unread_candidates
  输入:  limit(默认 200), excludeDismissed?(true)
  输出:  repoId, fullName, starredAt, hasNote, language, topics
  复用:  RepoRepository + statusMap（HomeViewModel 同款 implicit unread）

Tool 2: get_user_using_repos
  输入:  limit(默认 20)
  输出:  repoId[], embeddings optional
  用途:  semantic 近邻信号

Tool 3: get_recent_releases_for_starred
  输入:  withinDays(默认 7)
  输出:  repoId[], releaseTag, publishedAt
  复用:  Release 订阅 / 缓存

Tool 4: compute_unread_priority_scores
  输入:  candidates[], usingRepos[], recentReleases[], weights?
  输出:  ScoredRepo[] { repoId, score, signals[] }
  内部:  **纯 Swift**（§3.2）

Tool 5: fetch_repo_reading_context
  输入:  repoIds[] (max 8)
  输出:  description, summaryOneLiner?, readmeLengthEstimate, healthBadge
  复用:  RepoAIContextProvider / AISummaryRepository

Tool 6: generate_activation_copy
  输入:  scoredRepos top 8, userLocale
  输出:  ActivationItem[] { repoId, headline, reason, suggestedAction }
  内部:  LLM；@Generable；**不得改变排序**（MVP）

Tool 7: record_activation_feedback
  输入:  repoId, action: opened|dismissed|markedUsing|snoozed
  输出:  ok
  用途:  冷却与后续推荐优化

Tool 8: preview_status_change（dry_run）
  输入:  repoId, newStatus: using|read
  输出:  warning if any
  注:  apply 仅 UI 按钮，非 Agent step
```

### 4.2 关键约束

- Top N 默认 **5**（Free **3**）；
- `generate_activation_copy` **禁止**编造 release / note 内容；
- dismiss **必须**写 feedback 表，14 天内不再推荐；
- 不推荐 `status == using` 的 repo。

---

## 五、Agent 编排循环

```
[Step 1] system: Unread 激活助手；只推荐 unread；理由必须基于 signals
[Step 2] parallel: list_unread_candidates + get_user_using_repos + get_recent_releases
[Step 3] tool: compute_unread_priority_scores
[Step 4] tool: fetch_repo_reading_context(top 8 by score)
[Step 5] tool: generate_activation_copy → Top 5 卡片文案
[Step 6] final_answer + ActivationPayload JSON → UI
```

**maxSteps = 6**；多数路径 **1 次 LLM**（copy 生成）。

---

## 六、UI 落地

### 6.1 入口

| 入口 | 说明 |
|------|------|
| **Agent → 消化 → 今日激活** | 主列表页 |
| **Home 首屏卡片** | 有 unread > 50 时展示 |
| **RepoListView status=unread** | 工具栏「AI 挑 5 个」 |
| **与 03 周报并列** | 同一「消化」Tab 下两个卡片 |

### 6.2 卡片 UI

```
┌─ 今日激活 · 2026-06-27 ────────────────────────────────┐
│  从 1,240 个未读中为你选出 5 个                            │
│                                                          │
│  ┌─ #1 denoland/fresh ─────────────────── ⭐ 82 ────┐  │
│  │  你 45 天前 star，上周发了 v2.0；与你正在用的       │  │
│  │  sveltekit 同属 edge SSR 方向。                      │  │
│  │  ~12 分钟阅读 · 有 AI 摘要                          │  │
│  │  [阅读] [标为 using] [本周跳过]                      │  │
│  └────────────────────────────────────────────────────┘  │
│  … #2 ~ #5                                               │
│                                                          │
│  [换一批] [查看全部 unread] [反馈不准]                    │
└──────────────────────────────────────────────────────────┘
```

### 6.3 交互与写操作

| 按钮 | 行为 |
|------|------|
| **阅读** | 打开 detail + README；**不自动**改 read（沿用现有 markAsReadIfNeeded 规则） |
| **标为 using** | 预览 → 确认 → `set_repo_status(using)` |
| **本周跳过** | `record_activation_feedback(dismissed)` |
| **换一批** | 排除当前 5 个再跑（+1 quota） |

---

## 七、数据闭环

### 7.1 复用已有

| 模块 | 用途 |
|------|------|
| `HomeViewModel.statusMap` / `RepoStatus` | unread/using/read |
| `SemanticSearchService` | using 近邻 |
| Release 仓库与 poller | 近期发版信号 |
| `RepoHealthCalculator` | 活跃度 |
| `RepoAIInsightService` / summaries | 阅读成本 |
| `ReadmeViewModel` / 缓存 | v1.1 是否读过 |

### 7.2 新增 `unread_activation_feedback` 表

```sql
CREATE TABLE unread_activation_feedback (
    repo_id INTEGER NOT NULL,
    action TEXT NOT NULL,           -- opened|dismissed|markedUsing|snoozed
    activation_run_id TEXT,         -- 可选，关联某次推荐批次
    created_at TEXT NOT NULL,
    PRIMARY KEY (repo_id, created_at)
);
CREATE INDEX idx_activation_feedback_repo ON unread_activation_feedback(repo_id, created_at DESC);
```

**用途**：dismiss 冷却、转化率分析、prompt 迭代。

### 7.3 可选 `unread_activation_runs` 表

```sql
CREATE TABLE unread_activation_runs (
    id TEXT PRIMARY KEY,
    items_json TEXT NOT NULL,       -- Top N 快照
    unread_pool_count INTEGER NOT NULL,
    created_at TEXT NOT NULL
);
```

- 本地历史「上周推了啥」；
- 不同步 CloudKit（v1）。

---

## 八、付费与配额

| 档 | 体验 |
|----|------|
| **Free** | 每日 **1 次**激活（Top 3）；无「换一批」 |
| **Pro** | 不限刷新；Top 5~10 可配置；Release 触发插入 |

**Quota**：

- Scoring + 召回：**0 LLM**；
- `generate_activation_copy`：**1 quota / run**；
- 「换一批」= 新 run = 再 1 quota。

---

## 九、工作量估算

| 模块 | 类型 | 估算 |
|------|------|------|
| Scoring engine（纯 Swift） | 新增 | 中 |
| 6 个 Agent tools | 新增 | 小~中 |
| 激活卡片 UI + Home 入口 | 新增 | 中 |
| feedback 表 + DAO | 新增 | 小 |
| 单测（分数 / dismiss 冷却） | 新增 | 中 |
| i18n `agent.digest.unread.*` | 新增 | 小 |

**总估时**：**中**（难点在 scoring 调参 UX，不在 Agent loop）。

---

## 十、关键风险与缓解

| 风险 | 等级 | 缓解 |
|------|------|------|
| 推荐永远同一批热门 repo | 中 | 换一批 + dismiss 冷却 + starredAt 分桶轮换 |
| 理由幻觉 | 高 | signals[] 传入 LLM；客户端校验 reason 引用 signals |
| implicit unread 全库太大 | 中 | 先 score 200 采样再扩 |
| 与 03 周报内容重复 | 低 | 03 仅新 star；14 仅 unread 池 |
| 用户压力感（「又有任务」） | 中 | 文案用「建议」非「必须」；默认 Top 3 |

---

## 十一、后续拓展

1. **Snooze 7 天**后再推同一 repo；
2. **与 12 联动**：卡片上「问我关于这个 repo」→ 回忆搜索带 repo 上下文；
3. **FM 本地**（macOS 26）：copy 生成走端侧，降 quota；
4. **Widget**：菜单栏显示「今日 1 个未读优先」。

---

## 十二、变更记录

| 日期 | 变更 | 作者 |
|------|------|------|
| 2026-06-27 | 初稿 | Claude |
