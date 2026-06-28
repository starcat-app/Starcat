# Untagged 批量整理 Agent 方案（整理线）

> **文档定位**：对 **未打 tag** 的已 star 仓库做 **批量 AI 归类**；在现有 HOM-52 `BatchAIQueueService` 之上，增加 **Agent 层**（tag 体系规划、主题预聚类、一致化命名），仍遵守「预览 → 确认 → 写入」。
> **产品叙事**：[`10-Agent产品叙事-三条主线.md`](10-Agent产品叙事-三条主线.md) · **整理线**
> **状态**：方案稿（2026-06-27），等 dong4j 拍板立项。
> **与现有实现关系**：**不是重写**——[`BatchAIQueueService`](../../Starcat/Features/AI/BatchAIQueueService.swift) / `BatchAIUntaggedBanner` / `BatchAIOptionsSheet` 已落地 HOM-52；本方案描述 **Agent 化升级路径** 与 **冷启动扩展**。
> **关联文档**：
> - [`07-Smart-Collection-生成方案.md`](07-Smart-Collection-生成方案.md)：整理后可 NL 建集合
> - [`11-重叠扫描-Agent方案.md`](11-重叠扫描-Agent方案.md)：去冗余后可再批量打 tag
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)

---

## 一、用户故事

### 1.1 主流程（老用户 · Untagged 视图）

> 作为 Starcat 用户，Sidebar 点 **Untagged**，看到横幅「还有 1,200 个未分类仓库」。我点 **Agent 整理**（取代纯「批量 AI」），agent：
> 1. 扫描现有 **tag 体系** + untagged 样本，提议 **5~8 个顶层主题**（可复用已有 tag 名）
> 2. 把 untagged 按主题 **预聚类**（embedding / language / topics），每簇先跑 **代表 repo** 打 tag，再 **传播** 到簇内相似项（降 quota）
> 3. 队列逐 repo 生成 **标签建议 + 可选摘要**；默认 **不自动应用**（与 HOM-52 默认一致）
> 4. 我在 **BatchAIQueuePanel** 里看进度；完成后在 **预览页** 批量勾选采纳 tag

### 1.2 冷启动（新用户 · 首次 sync 后）

> 全量 sync 结束 → 弹窗：「1,842 stars，1,842 未分类」→ **[开始 Agent 整理]**  
> 可选：**静默模式**（复用 HOM-126 `AutoTidyScheduler` + `silent: true`）在后台跑前 200 个，其余用户手动续跑。

### 1.3 与 HOM-52 现有批量 AI 的差异

| 维度 | HOM-52 现有 | **13 Untagged Agent** |
|------|-------------|------------------------|
| 编排 | 固定 pipeline：`generateInsight` → tags | **先规划 tag 体系 + 聚类**，再 per-repo |
| 标签一致性 | 每 repo 独立推荐，易同名异写 | **簇级 tag 名约束** + 已有 tag 优先 |
| 成本 | N 次完整 insight | 代表 repo + 传播，**约降 40~60% quota** |
| UI 入口 | `BatchAIUntaggedBanner` | 同横幅，文案升级为「Agent 整理」 |
| 写操作 | `autoApplyTags` 可选 | 不变；**默认 false** |

---

## 二、核心价值

> **「降低 1800 untagged 的激活门槛」**——从「每个 repo 单独猜 tag」变成「先建 taxonomy，再批量填充」。

| 维度 | 手动打 tag | HOM-52 批量 AI | **Untagged Agent** |
|------|------------|----------------|---------------------|
| 学习成本 | 高 | 中 | **低**（可见主题簇） |
| tag 命名一致 | 用户自律 | 易漂移 | **体系预规划** |
| 新用户首日 | 劝退 | 可用 | **冷启动向导** |
| 与 Smart Collection | 无关 | 弱 | 整理完可 **07 NL 建集合** |

---

## 三、架构：Plan → Cluster → Queue → Review

### 3.1 四阶段管线

```text
Phase P — Plan（1 次 LLM + 本地统计）
  输入：现有 tags[] + untagged 统计(language/topics 分布) + 随机样本 30 repo
  输出：TagTaxonomyPlan { suggestedTags[], mergeHints[], maxTagsPerRepo: 3 }

Phase C — Cluster（无 LLM 或轻量）
  输入：全部 untagged repoIds
  输出：UntaggedCluster[] { themeLabel, repoIds[], representativeId }
  方法：language 分桶 + embedding 粗聚类（阈值低于 11 重叠扫描，|cluster|≥5）

Phase Q — Queue（复用 BatchAIQueueService）
  对每个 cluster：
    1. 先处理 representative → insight + tags（带 taxonomy 约束 prompt）
    2. 簇内其余：优先 **传播**（相似度≥0.85 且 tag 一致）→ 仅低置信度才 full insight
  串行 job；暂停/取消语义与 HOM-52 相同

Phase R — Review（UI）
  汇总：将应用 tag 数 / 新建 tag 数 / ignored 数
  用户确认 → bulk apply；或逐 job 在 panel 里改
```

### 3.2 与 `BatchAIQueueOptions` 的映射

| Options 字段 | Agent 方案 |
|--------------|------------|
| `actions` | 仍 `[.summary, .tags]`；Plan 阶段可选只要 `.tags` |
| `autoApplyTags` | **默认 false**；冷启动静默模式可 true + threshold 0.92 |
| `confidenceThreshold` | 传播路径单独阈值 0.88；full insight 仍 0.90 |
| `maxRetries` | 不变 |

---

## 四、工具集

### 4.1 工具清单

```
Tool 1: list_untagged_repos
  输入:  offset, limit(默认 100), language?, order(starredAt|stars)
  输出:  repoId, fullName, language, topics, description 截断
  复用:  TagRepository + RepoRepository（untagged 查询已有）

Tool 2: list_existing_tags
  输入:  includeCounts?(默认 true)
  输出:  tagId, name, color, repoCount
  复用:  TagRepository

Tool 3: sample_untagged_stats
  输入:  sampleSize(默认 30)
  输出:  languageHistogram, topTopics[], starredAtRange
  内部:  纯 Swift 聚合

Tool 4: plan_tag_taxonomy
  输入:  existingTags[], stats, sampleRepos[]
  输出:  TagTaxonomyPlan JSON
  内部:  单次 LLM；@Generable 强 schema

Tool 5: cluster_untagged_repos
  输入:  plan, threshold(默认 0.78)
  输出:  UntaggedCluster[]
  内部:  纯 Swift + embedding（同 11 文档 Phase A 简化版）

Tool 6: recommend_tags_for_repo
  输入:  repoId, taxonomyPlan, clusterTheme?
  输出:  TagRecommendation[] { name, confidence, createNew? }
  复用:  RepoAIInsightService 标签路径；prompt 注入 taxonomy

Tool 7: propagate_tags_in_cluster
  输入:  representativeTags[], candidateRepoIds[]
  输出:  { applied[], needsFullInsight[] }
  内部:  embedding 相似度 + 规则；**不调 LLM**

Tool 8: preview_bulk_tag_apply
  输入:  applications[] { repoId, tagNames[] }
  输出:  { newTagsToCreate[], assignments[], warnings[] }
  约束:  dry_run only

Tool 9: apply_bulk_tags（UI 确认后，非 Agent auto step）
  输入:  applications[], confirmed: true
  复用:  TagRepository + RepoTagRepository + BatchAIQueueService 落库逻辑
```

### 4.2 关键约束

- `plan_tag_taxonomy` 建议 tag 数 **5~12**；超出则客户端截断；
- 新建 tag **必须**在 preview 列出颜色默认值；
- `propagate_tags_in_cluster` 不得对 representative 未确认的标签传播（若 autoApply false）；
- Agent loop **不得**调用 `apply_bulk_tags`。

---

## 五、Agent 编排循环

### 5.1 批次启动（用户点「开始 Agent 整理」）

```
[Step 1] system: Untagged 整理助手；优先复用已有 tag；禁止自动写入
[Step 2] tools: list_existing_tags + sample_untagged_stats + list_untagged_repos(limit=30)
[Step 3] tool: plan_tag_taxonomy
[Step 4] tool: cluster_untagged_repos（全量 untagged，可能异步进度）
[Step 5] 构建 BatchAIQueueService jobs（representatives 优先排序）
[Step 6] 移交 Queue 执行（非 LLM loop；UI 绑 panel）
[Step 7] optional LLM: 生成批次总览 Markdown「本次将处理 N 个，分 K 簇」
```

**Agent 步数 ≤ 6**；长耗时在 Queue 层，不占用 chat steps。

### 5.2 单 repo fallback

传播失败或 `needsFullInsight` → 入队标准 `generateInsight`（HOM-52 原路径）。

---

## 六、UI 落地

### 6.1 入口

| 入口 | 说明 |
|------|------|
| **Untagged 横幅** | 升级 `BatchAIUntaggedBanner` 文案为 Agent 整理；按钮打开 `BatchAIOptionsSheet` + taxonomy 预览 |
| **Agent → 整理 → Untagged 批量整理** | 同功能，带 taxonomy 上一步预览 |
| **首次 sync 完成** | 冷启动 sheet（可跳过） |
| **设置 → 自动整理** | HOM-126 静默模式 + taxonomy 缓存（每周刷新 plan 一次） |

### 6.2 流程 UI

```text
1. BatchAIOptionsSheet（已有）
   + 新增折叠区「Tag 体系预览」（Plan 结果可编辑 tag 名后再开跑）

2. BatchAIQueuePanel（已有）
   + 簇标签 chip 显示当前 job 所属 theme
   + 传播成功 job 标记「⚡ 传播」vs「🤖 完整 AI」

3. 批次完成 Review Sheet（新增）
   ┌─ 整理完成 ─────────────────────────────┐
   │  将新建 tag: macos-tools, rust-cli (2)   │
   │  将打标: 847 repos · 忽略: 53 · 失败: 2 │
   │  [查看失败] [预览 tag 分配] [确认应用]     │
   └──────────────────────────────────────────┘
```

### 6.3 与 AI 保守策略

- 默认 **Review Sheet 确认** 后才 `apply_bulk_tags`；
- `autoApplyTags=true` 时仅应用 **≥threshold** 且 **taxonomy 内已有 tag 名**；
- 新建 tag 名 **永远** 要用户可见（preview 列表）。

---

## 七、数据闭环

### 7.1 复用已有

| 模块 | 用途 |
|------|------|
| `BatchAIQueueService` | Queue 执行、暂停、通知 |
| `BatchAIQueueModels` | Job 状态机 |
| `RepoAIInsightService.generateInsight` | 标签 + 摘要 |
| `TagRepository` / `RepoTagRepository` | 读写 tag |
| `AutoTidyScheduler`（HOM-126） | 静默冷启动 |
| `EntitlementGate.batchAI` | Pro 门控 |
| `SemanticSearchService` | 聚类与传播 |

### 7.2 新增 `untagged_tidy_plans` 表（可选）

```sql
CREATE TABLE untagged_tidy_plans (
    id TEXT PRIMARY KEY,
    taxonomy_json TEXT NOT NULL,
    cluster_count INTEGER NOT NULL,
    untagged_count_at_plan INTEGER NOT NULL,
    created_at TEXT NOT NULL
);
```

- 缓存最近一次 Plan，避免每次开跑都调 LLM；
- untagged 数量变化 >10% 时 invalidate。

### 7.3 不引入

- 不持久化 Queue jobs（与 HOM-52 一致，见 `BatchAIQueueService` 文件头）；
- 不在 Agent loop 存完整 insight 原文（已有 `ai_summaries`）。

---

## 八、付费与配额

| 档 | 体验 |
|----|------|
| **Free** | 每批最多 **50** untagged；仅 Plan + 1 簇试点；无静默自动 |
| **Pro** | 全量 batch；静默 AutoTidy；传播降本 |

**Quota 估算**（1000 untagged）：

| 路径 | 次数 |
|------|------|
| Plan + Cluster | 1 LLM + 0 |
| 代表 repo full insight | ~80（K 簇 × 代表 + 传播失败） |
| 传播-only | 0 LLM |
| **合计** | **~80 quota** vs HOM-52 纯 pipeline **~1000** |

---

## 九、工作量估算

| 模块 | 类型 | 估算 |
|------|------|------|
| Plan + Cluster tools | 新增 | 中 |
| 传播逻辑 + Queue 集成 | 扩展 BatchAIQueueService | 中 |
| Taxonomy 预览 UI | 扩展 BatchAIOptionsSheet | 小 |
| Review Sheet | 新增 | 中 |
| 冷启动 sheet | 新增 | 小 |
| 单测（传播阈值 / taxonomy 校验） | 新增 | 中 |
| i18n `agent.organize.untagged.*` | 新增 | 小 |

**总估时**：**中**（大量复用 HOM-52，增量在 Plan/Cluster/传播）。

---

## 十、关键风险与缓解

| 风险 | 等级 | 缓解 |
|------|------|------|
| taxonomy 漂移（LLM 造太多新 tag） | 高 | 优先 existingTags；新建上限 5/批 |
| 传播误标 | 高 | 高阈值 0.85；误标走 panel 单条 ignore |
| 与 11 重叠扫描结论冲突 | 中 | 先重叠再去重 untagged 整理 |
| 1000+ queue 一夜跑完 API 限流 | 中 | 串行 + 可选 inter-job delay |
| 用户以为 autoApply 默认开 | 中 | UI 强提示；默认 false 不变 |

---

## 十一、变更记录

| 日期 | 变更 | 作者 |
|------|------|------|
| 2026-06-27 | 初稿 | Claude |
