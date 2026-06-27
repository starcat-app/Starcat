# 重叠 / 冗余扫描 Agent 方案（整理线）

> **文档定位**：扫描用户 **已 star 仓库** 中的功能重叠簇，给出「保留谁 / 可考虑 unstar 谁 / 如何打 tag」建议；用户确认后才写入。
> **产品叙事**：[`10-Agent产品叙事-三条主线.md`](10-Agent产品叙事-三条主线.md) · **整理线**
> **状态**：方案稿（2026-06-27），等 dong4j 拍板立项。
> **关联文档**：
> - [`02-替代品推荐-Agent方案.md`](02-替代品推荐-Agent方案.md)：发现线「向外找替代」；本方案是「向内去冗余」
> - [`07-Smart-Collection-生成方案.md`](07-Smart-Collection-生成方案.md)：扫描后可一键生成 Smart Collection 固化簇
> - [`04-AgentRunKit-Swarm-SwiftAgent-对比分析.md`](04-AgentRunKit-Swarm-SwiftAgent-对比分析.md)：共用 AgentRuntime
> - [`../详细设计/26-向量搜索改进.md`](../详细设计/26-向量搜索改进.md)：embedding 索引

---

## 一、用户故事

### 1.1 主流程

> 作为 Starcat 用户，我的 stars 已经 1800+，明显感到「同一类工具 star 了太多份」。我打开 **Agent → 整理 → 库体检 → 重叠扫描**，agent：
> 1. 找出 12 组「高度相似」的 repo 簇（例如 5 个 React 状态管理、3 个 macOS 窗口管理）
> 2. 每组给一句 **簇主题** + **推荐保留 1~2 个** 的理由（活跃度、OpenSSF、你的 note/status）
> 3. 对其余 repo 标记为「可考虑 unstar」或「合并到 tag: 待清理」
> 4. 我 **预览 diff** → 勾选采纳项 → 确认后批量 unstar / 打 tag

### 1.2 次要触发

| 触发 | 说明 |
|------|------|
| **季度提醒** | 设置页「每 90 天提醒库体检」→ 可选跑重叠扫描 |
| **导入后 D+7** | 冷启动整理完成后，提示「要查重复吗？」 |
| **Smart Collection 前** | 07 NL 创建前，可选「先扫描重叠再建集合」 |

### 1.3 与发现线「替代品」的差异

| 维度 | 09/02 替代品 | **11 重叠扫描** |
|------|--------------|-----------------|
| 检索范围 | 源 repo → **GitHub 全网**候选 | **仅本地已 star** |
| 目标 | 找更好的外部项目 | 清理库内冗余 |
| 写操作 | star 候选 | unstar / tag / status |
| 典型用户 | 「这个老了，换哪个？」 | 「我 star 太多同类了，留谁？」 |

---

## 二、核心价值

> **「基于个人 stars 库的结构性体检」**——GitHub 不会告诉你「你收藏了 5 个 Zustand 竞品」，Trending 也不会。

| 维度 | 现有 Starcat | 重叠扫描 Agent |
|------|--------------|----------------|
| 语义搜索 | 单 query → 相关列表 | **无 query 全库聚类** → 重叠簇 |
| Repo Health | 单 repo  sheet | **簇内横向对比**活跃度 |
| Tags | 手动归类 | 建议「簇 tag」+ 合并命名 |
| 批量 AI | Untagged 打 tag | **相似度驱动**的去重建议 |

**核心差异化**：把「语义搜索」从 **检索工具** 升级为 **库结构分析**。

---

## 三、算法设计（两阶段：确定性聚类 + LLM 解读）

### 3.1 为什么不用「纯 LLM 扫 1800 个 repo」

- Token / 成本不可接受；
- 相似度不稳定、不可复现；
- 无法做单元测试。

**选定方案**：**embedding 聚类（确定性）+ LLM 只解读 top 簇（可控成本）**。

### 3.2 Phase A — 候选簇生成（无 LLM）

```text
输入：全部 is_starred=1 的 repos（N ≈ 500~3000）
  │
  ├─ 预过滤：archived 可选单独成簇；language 为空归「unknown」桶
  ├─ 按 language 分桶（减少跨语言误聚）
  ├─ 桶内取向量：SemanticSearchService 已有 repo_embeddings
  │     缺失向量的 repo → 跳过或触发 ensureIndexed（后台，不阻塞 UI）
  ├─ 相似度：cosine ≥ T_high（默认 0.82）连边 → 连通分量 = 一簇
  │     T_high 可配置；参见 SemanticSearchHit 经验区间 [0.30, 0.95]
  ├─ 簇大小过滤：只保留 |cluster| ≥ 3（2 个相似对噪声太大）
  └─ 输出：OverlapCluster[]（repo IDs + pairwise avg score）
```

**可选增强（v1.1）**：

- 同一 `topics` 交集 ≥ 2 的 repo 强制同簇候选；
- FTS：description 里 mutual keyword Jaccard ≥ 0.4 加权连边。

### 3.3 Phase B — 簇解读与保留建议（LLM + 结构化输出）

对每个 cluster（最多处理 **top 20 簇** by size × avg similarity，防 quota 爆炸）：

```text
输入：簇内每个 repo 的
  - fullName / description / language / topics
  - stars / pushedAt / isArchived
  - user note 前 200 字 / status(read|using|unread)
  - RepoHealth / OpenSSF 摘要（有则）
  │
  LLM 输出 @Generable / JSON schema：
  {
    "theme": "React 状态管理",
    "summary": "…",
    "keep": [{ "repoId", "reason" }],      // 1~2 个
    "considerRemove": [{ "repoId", "reason" }], // 其余
    "suggestedTag": "react-state-mgmt"     // 可选
  }
```

**硬规则（客户端校验，不信任 LLM）**：

- `status == using` 的 repo **不得**进入 `considerRemove`；
- 有非空 user note 的 repo 默认 **keep**，除非用户勾选「允许建议 unstar 有 note 的」；
- `isArchived == true` 默认 `considerRemove` 优先级最高。

---

## 四、工具集

### 4.1 工具清单

```
Tool 1: list_starred_repos_for_scan
  输入:  limit?, language?, minStars?, excludeArchived?(默认 false)
  输出:  repoId / fullName / language / topics / status / hasNote 摘要列表
  复用:  RepoRepository.fetchAllStarred

Tool 2: fetch_repo_embeddings_batch
  输入:  repoIds[] (max 200/批)
  输出:  { repoId: vectorPresent } + 缺失列表
  复用:  RepoEmbeddingRepository + SemanticIndexBuilder（缺失时排队索引）

Tool 3: compute_overlap_clusters
  输入:  threshold(默认 0.82), minClusterSize(默认 3), languageBucket?(可选)
  输出:  OverlapCluster[] { clusterId, repoIds[], avgSimilarity, language }
  内部:  Phase A 纯 Swift；**不调 LLM**

Tool 4: get_cluster_repo_details
  输入:  repoIds[] (max 15)
  输出:  每 repo 元数据 + health + openSSF + note 截断 + status
  复用:  RepoHealthCalculator / OpenSSF 缓存 / RepoNoteRepository

Tool 5: interpret_overlap_cluster
  输入:  clusterId, repoDetails[]
  输出:  ClusterInterpretation JSON（theme / keep / considerRemove / suggestedTag）
  内部:  单次 LLM；失败返回结构化 error，不拖垮整次 scan

Tool 6: preview_apply_cluster_actions
  输入:  actions[] { type: unstar|addTag|setStatus, repoId, tagName? }
  输出:  { affectedCount, samples[], warnings[] }  // 只读预览
  复用:  与 MCP write facade 同款 dry_run 语义

Tool 7: apply_cluster_actions（用户确认后单独调用，非 Agent 自动步）
  输入:  actions[], confirmed: true
  输出:  成功/失败 per repo
  约束:  **不得**出现在 Agent 自动 loop 里；仅 UI「确认应用」按钮触发
```

### 4.2 Tool schema 关键约束

- `compute_overlap_clusters` **必须本地执行**，禁止 LLM 臆造簇；
- `interpret_overlap_cluster` 每轮 scan 最多调 **20 次**（硬 cap）；
- `apply_cluster_actions` **never auto-invoke**——违反即不合规；
- 所有 tool result JSON **单条 ≤ 8KB**（簇内 repo 多时用 repoId 引用，详情另 tool 拉）。

---

## 五、Agent 编排循环

### 5.1 全自动 scan（用户点「开始扫描」）

```
[Step 1] system: 重叠扫描助手；只分析本地 stars；禁止自动 unstar
[Step 2] user: （隐式）run full scan
[Step 3] tool: list_starred_repos_for_scan → N repos
[Step 4] tool: fetch_repo_embeddings_batch（分批直到覆盖率 ≥ 90% 或超时）
[Step 5] tool: compute_overlap_clusters → K 簇
[Step 6] loop top min(K, 20):
           tool: get_cluster_repo_details
           tool: interpret_overlap_cluster
[Step 7] LLM: 写总览 Markdown（共 K 簇，重点解读 top 5）
[Step 8] final_answer → UI 渲染簇卡片列表
```

**最大步数**：8 + 2×min(K,20)；实际用 **子任务进度条** 而非逐步 chat 气泡（见 §6）。

### 5.2 单簇深入（用户点开某一簇）

```
user: "展开 cluster-7 详情"
→ get_cluster_repo_details + interpret（若尚未解读）
→ 可选 compare_repos_table（复用 09 的对比表 tool）
→ UI 展示 keep / remove 建议 + 勾选框
```

---

## 六、UI 落地

### 6.1 入口

| 入口 | 路径 |
|------|------|
| **主入口** | Sidebar **Agent → 整理 → 重叠扫描** |
| **设置页** | 数据与同步 → 「库体检」 |
| **触手** | Untagged 视图 banner：「stars 过多？去重叠扫描」 |

### 6.2 主界面（Sheet / Agent 中心页）

```
┌─ 库体检 · 重叠扫描 ─────────────────────────────────────┐
│  已扫描 1,842 个 stars · 向量覆盖 96% · 发现 12 组重叠    │
│  [████████░░] 解读簇 8/12                                 │
│                                                          │
│  ┌─ 簇 #1 · React 状态管理（5 个）────────────────────┐  │
│  │  相似度均值 0.87 · 语言 TypeScript                  │  │
│  │  ✅ 建议保留: zustand（using · 最近 push 3 天前）    │  │
│  │  ⚠️ 可考虑移除: recoil, jotai（unread · 1 年未更新）│  │
│  │  [展开对比表] [全选移除项] [建议 tag: react-state]   │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌─ 簇 #2 · macOS 窗口管理（3 个）…                     │  │
│                                                          │
│  ── 预览将执行 ──                                        │
│  unstar × 4 · 新增 tag × 1 · 不影响 using × 0           │
│                                                          │
│              [预览 diff]  [确认应用]  [导出报告]  [关闭]   │
└──────────────────────────────────────────────────────────┘
```

### 6.3 关键交互

| 操作 | 行为 |
|------|------|
| **确认应用** | 调 `apply_cluster_actions`；逐项 toast；失败不回滚已成功项 |
| **导出报告** | Markdown 下载；不写 DB |
| **建议 tag** | 预览 → 确认 → `create_tag` + `assign_tags`（MCP 同款门控） |
| **停止** | cancel Task；保留已完成簇解读 |

### 6.4 错误处理

| 错误 | UI |
|------|-----|
| 向量覆盖率 < 60% | 提示先跑「语义索引」；提供跳转设置 |
| 0 簇 | 「未发现 ≥3 个相似 repo 的簇」+ 调低阈值说明 |
| LLM 解读单簇失败 | 该簇显示「仅相似度数据，无 AI 解读」 |
| unstar GitHub API 失败 | 该项标红，其余继续 |

---

## 七、数据闭环

### 7.1 复用 Starcat 已有

| 模块 | 用途 |
|------|------|
| `SemanticSearchService` / `repo_embeddings` | Phase A 聚类 |
| `SemanticIndexBuilder` | 扫描前补索引 |
| `RepoRepository.searchFTS` | 可选字面增强 |
| `RepoHealthCalculator` / OpenSSF | 保留建议信号 |
| `RepoNoteRepository` / status | 保护 using + 有 note |
| `BatchAIQueueService` | 大批量索引构建队列 |
| `StarcatMCPWriteFacade` dry_run | 预览语义 |
| `EntitlementGate` | Pro 门控 |

### 7.2 新增 `overlap_scan_reports` 表

```sql
CREATE TABLE overlap_scan_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id TEXT NOT NULL UNIQUE,           -- UUID
    cluster_count INTEGER NOT NULL,
    repo_count_scanned INTEGER NOT NULL,
    embedding_coverage REAL NOT NULL,         -- 0.0~1.0
    report_json TEXT NOT NULL,                -- OverlapCluster[] + interpretations
    applied_actions_json TEXT,              -- NULL 直到用户确认应用
    created_at TEXT NOT NULL                  -- ISO8601
);
CREATE INDEX idx_overlap_scan_created ON overlap_scan_reports(created_at DESC);
```

**用途**：

- 扫描结果可 **稍后继续**（不必一次应用完）；
- 对比两次 scan「库是否变干净」；
- **不同步 CloudKit**（报告含大量 repo 元数据快照，体积大；v1 本地 only）。

### 7.3 不存什么

- 不存 pairwise 全矩阵（N² 太大）；
- 不存 LLM raw thinking（走 `AIDebugLogger`）；
- 不在 Agent loop 内写 `applied_actions`。

---

## 八、付费与配额

| 档 | 体验 |
|----|------|
| **Free** | 每月 1 次全库 scan；只解读 **top 5 簇**；不可批量 unstar（仅导出建议） |
| **Pro** | 每月 4 次；解读 top 20 簇；预览 + 批量 apply；导出 Markdown |

**Quota 模型**：

- Phase A（聚类）：**0 LLM quota**（纯本地）；
- Phase B：每簇 `interpret_overlap_cluster` = **0.2 quota**，向上取整，单次 scan 上限 **5 quota**；
- 用户确认 apply：**0 quota**（GitHub API only）。

---

## 九、工作量估算

| 模块 | 类型 | 估算 |
|------|------|------|
| `compute_overlap_clusters`（Union-Find + cosine） | 新增 | 中 |
| embedding 批量缺失处理 | 扩展 | 小 |
| 5 个 Agent Tool + interpret prompt | 新增 | 中 |
| `overlap_scan_reports` + DAO | 新增 | 小 |
| Agent 整理页 UI + 预览 diff | 新增 | 中 |
| apply 流程（unstar + tag） | 扩展 StarService / TagRepo | 小 |
| 单测（聚类边界 / using 保护规则） | 新增 | 中 |
| i18n `agent.organize.overlap.*` | 新增 | 小 |

**总估时**：**中**（难点在 Phase A 聚类性能与 UX 进度，不在 LLM）。

---

## 十、关键风险与缓解

| 风险 | 等级 | 缓解 |
|------|------|------|
| 误聚（不同项目 cosine 虚高） | 高 | language 分桶 + topics 交集约束 + UI 展示 avgSimilarity 供人工判断 |
| 误杀 using / 有 note 的 repo | **致命** | 客户端硬规则；默认不 suggest remove |
| 1800 repo 聚类耗时 | 中 | 分桶 + 仅桶内 O(n²) 或 ANN（v2）；进度条 + 可取消 |
| 向量未索引导致漏簇 | 中 | 扫描前检查覆盖率；<60% 阻断并引导索引 |
| 用户一次性 unstar 过多后悔 | 中 | 预览 diff + 单次 apply 上限 20 + 无 auto apply |
| 与 02 替代品结论矛盾 | 低 | 02 推外部；11 清内部；文案区分 |

---

## 十一、后续拓展

1. **与 07 联动**：扫描完一键「为每簇创建 Smart Collection」
2. **时间维度**：「2024 前后 star 的同类项目」分簇
3. **fork 检测**：同一 upstream 的 fork 归并建议
4. **Swarm Workflow**：macOS 26+ 上 `parallel interpret clusters`（见 04 文档 Phase 2）

---

## 十二、变更记录

| 日期 | 变更 | 作者 |
|------|------|------|
| 2026-06-27 | 初稿 | Claude |
