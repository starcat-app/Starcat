# README 预拉与 Repo Health 首次预热最终方案

> 日期：2026-07-01  
> 状态：最终方案确认，待实施  
> 范围：新用户首次 starred 数据同步完成后的 README 预拉与 Repo Health 分数计算

## 背景

README 预拉和 Repo Health 计算都属于“新用户首次使用时应该尽快补齐、但不能影响前台体验”的后台数据预热能力。

现有实现已经具备两个基础能力：

- README 预拉：`ReadmePrefetchService` / `ReadmePrefetchPoller` 小批量补齐 `readmes` 与 `readme_contents`。
- Repo Health：`RepoHealthService` / `RepoHealthPoller` 基于本地 Repo、Release、OpenSSF 缓存计算健康度快照。

但现有模型偏向周期性兜底，缺少明确的“首次预热作业”语义。新用户首次登录后，starred 数据会分页同步；如果 README 或 Health 过早启动，只能覆盖部分仓库。如果用户关闭应用、遇到 GitHub 限流或清理本地缓存，也缺少可解释、可恢复的作业状态。

## 目标

1. 首次登录后，必须等 starred 数据全量同步完成，再启动首次预热。
2. 首次预热是一个可恢复作业，不依赖内存 Task 状态。
3. README 预拉和 Repo Health 首次计算都要覆盖当前 starred 仓库集合。
4. 应用关闭、崩溃、GitHub 限流、普通网络失败后，下次启动可以从本地状态恢复。
5. 周期性 poller 保留，但职责降级为 completed 后的兜底补漏与 stale 刷新。
6. 设置页“立即拉取”重新定义为“立即补齐 README”，只影响 README，不触发 Repo Health。

## 非目标

- 不处理 Starcat 内部新 star 后的单仓库预热链路。
- 不修改全局搜索、Explore、Weekly、Trending 等 star 按钮刷新逻辑。
- 不让 Repo Health 首次计算主动拉取每个 repo 的最新 GitHub metadata / release。
- 不把清理 README 缓存解释为“重新执行首次预热”。
- 不绕过 GitHub 限流或失败冷却强制重试。

## 总体模型

新增一个持久化协调层：

```text
InitialRepoWarmupCoordinator
├── README 首次覆盖
├── Repo Health 首次计算
└── 状态窗口进度源
```

执行流程：

```text
已登录
→ starred 数据全量同步 completed
→ 首次 warmup 未完成
→ 延迟 5 分钟
→ README 首次覆盖
→ Repo Health 首次计算
→ 标记首次 warmup completed
```

周期性任务仍保留：

- `ReadmePrefetchPoller`：失败重试、缓存过期、清理缓存后的补漏。
- `RepoHealthPoller`：按 `stale_after` 刷新已有或过期的 Health 快照。

首次 warmup 未完成时，poller 不应抢同一批候选，避免重复执行和状态冲突。

## 持久化状态

新增轻量表 `initial_warmup_jobs`，按 GitHub user 隔离：

```text
user_id
phase
scheduled_at
started_at
completed_at
next_retry_at
last_error_kind
readme_covered
readme_total
health_covered
health_total
updated_at
```

`phase` 建议取值：

```text
waiting
readme
health
paused
completed
disabled
```

不要持久化完整 repo 队列。每批执行前都从 SQLite 重新查询候选，这样应用关闭或崩溃后，只要根据 DB 事实重新计算覆盖率即可恢复。

## 触发条件

首次 warmup 只能由 starred 全量同步完成触发：

```text
authSession.state.isAuthenticated == true
syncManager.state == .completed
settings.readmePrefetchEnabled == true
job.phase != completed
```

首次触发后写入：

```text
phase = waiting
scheduled_at = now + 5 min
```

如果应用在 5 分钟内关闭，下次启动恢复时：

- `scheduled_at > now`：继续等待剩余时间。
- `scheduled_at <= now`：直接进入 README 阶段，不重新等待完整 5 分钟。

## README 阶段

README 阶段复用 `ReadmePrefetchService` 的低优先级串行策略：

- 单批 100 条。
- 单仓间隔 1 秒。
- 连续批次等待 5 秒。
- 尊重 `readme_prefetch_states.next_retry_at`。
- 遇到全局限流时暂停作业。

README 覆盖判定必须改为“已缓存或已确认无 README”：

```text
已覆盖 =
  readmes 存在 且 readme_contents 存在
  或 readme_prefetch_states.html_status == notFound
  或 readme_prefetch_states.markdown_status == notFound
```

临时网络失败、parse error、rate limited 不算覆盖，只进入冷却或等待重试。

原因：部分仓库天然没有 README。如果只用 HTML + Markdown 是否存在作为完成条件，首次 warmup 会永远达不到 100%。

## Repo Health 阶段

Repo Health 首次阶段只处理缺失快照的 starred repo：

```sql
SELECT repos.*
FROM repos
LEFT JOIN repo_health_snapshots h ON h.repo_id = repos.id
WHERE repos.is_starred = 1
  AND h.repo_id IS NULL
ORDER BY repos.starred_at DESC
LIMIT ?
```

首次阶段不处理已有但 stale 的 Health 分数。已有分数的过期刷新交给 `RepoHealthPoller`。

计算策略沿用当前自动路径：

- 使用本地 `repos` 元数据。
- 使用本地 `releases` 缓存。
- 使用本地 OpenSSF 缓存。
- 不为每个 repo 主动调用 GitHub `/repos` 或 releases API。

这样首次 Health 可以低成本覆盖大量仓库，不会和 starred 同步、README 预拉争抢 GitHub 配额。

## 关闭应用与崩溃恢复

恢复逻辑只依赖持久化 job 状态和当前 DB 覆盖率：

| 关闭时机 | 下次启动行为 |
|---|---|
| `waiting` 且未到 `scheduled_at` | 继续等待剩余时间 |
| `waiting` 且已过 `scheduled_at` | 直接进入 README 阶段 |
| README 跑到一半 | 重新查询未覆盖 README 的 starred repo，继续跑 |
| README 已完成、Health 未完成 | 从 Health 阶段继续 |
| 单个 repo 处理中崩溃 | 该 repo 没写成功状态，下次会重新成为候选 |
| `completed` 后重启 | 不再启动首次 warmup，只保留 poller 兜底 |

进度显示不应只用累计处理数。每批结束后重新计算：

```text
readme_covered / readme_total
health_covered / health_total
```

这样用户清理缓存、同步新增数据或失败冷却变化后，状态仍然反映当前真实覆盖率。

## GitHub 限流与失败恢复

遇到 GitHub rate limit：

```text
phase = paused
next_retry_at = retryAfter 或至少 now + 60s
last_error_kind = rateLimited
```

恢复策略：

- 应用仍打开：到 `next_retry_at` 后自动继续。
- 应用已关闭：下次启动发现 `next_retry_at <= now` 后继续。
- 状态窗口显示“等待 GitHub 限流恢复”。

普通网络错误：

- 单 repo 失败写入 `readme_prefetch_states.next_retry_at`。
- 作业继续处理其他候选。
- 如果当前没有可处理候选但覆盖率未完成，进入 `paused`，等待最早可重试时间。

401 / 未登录：

- 立即暂停。
- 重新登录且 user_id 一致后恢复。
- 切换账号时按新 user_id 创建或恢复独立 job。

## README 缓存清理语义

清理 README 缓存不重置首次 warmup completed 状态。

分两种情况：

1. 首次 warmup 未完成时清理 README 缓存：
   - 当前缓存消失。
   - 下一批候选查询重新看到缺失项。
   - 作业继续执行。
   - 完成判定仍以当前覆盖率为准。

2. 首次 warmup 已完成后清理 README 缓存：
   - 不把 `phase` 改回未完成。
   - 不自动启动大规模首次 warmup。
   - 交给周期性 `ReadmePrefetchPoller` 兜底补回。
   - 用户可在设置页手动点击“立即补齐 README”。

普通清理只删除 README HTML / Markdown 缓存，不应删除 `readme_prefetch_states`。`readme_prefetch_states` 里的 notFound、失败冷却和错误类别仍然有效，避免清理后马上重复请求已确认无 README 或仍在冷却的仓库。

如果未来需要“重置 README 预拉状态”，应作为 Debug 或高级操作单独提供，不和普通清理缓存合并。

## 设置页“立即补齐 README”

现有“立即拉取”按钮的语义调整为：

```text
立即补齐 README
```

英文建议：

```text
Fetch Missing READMEs
```

语义边界：

- 只处理 README，不处理 Repo Health。
- 处理当前 DB 里缺失、过期或可重试的 README 候选。
- 可以绕过首次 warmup 的 5 分钟等待。
- 不绕过 GitHub 限流。
- 不强行重试仍在 `next_retry_at` 冷却中的 repo。
- 不重置首次 warmup completed 状态。

不同阶段行为：

| 当前状态 | 点击后行为 |
|---|---|
| 首次 warmup `waiting` | 立即进入 README 阶段 |
| 首次 warmup `readme` | 若未运行则继续 README；运行中按钮禁用 |
| 首次 warmup `health` | 只补 README，不影响 Health 阶段 |
| 首次 warmup `completed` | 普通手动补漏，适合清理缓存后使用 |
| 限流暂停 | 禁用，等待 `next_retry_at` |
| 未登录 / 设置关闭 | 禁用 |

Repo Health 不挂到这个按钮上，避免“立即拉取”被误解为重新计算分数。

## 状态窗口展示

状态窗口应展示首次 warmup 作为一个后台任务：

```text
首次数据预热
README 240 / 1800
Repo Health 0 / 1800
```

暂停时展示固定原因：

```text
首次数据预热：等待 GitHub 限流恢复
```

完成后可以隐藏，或显示最近完成时间。周期性 poller 的普通补漏不需要长期占据状态窗口，除非正在运行。

## 实施步骤

1. 新增 `initial_warmup_jobs` 表与 Repository。
2. 新增 `InitialRepoWarmupCoordinator`，接管首次 waiting / readme / health / paused / completed 状态机。
3. 调整 README 覆盖统计，把 notFound 计入已覆盖。
4. 为 Repo Health Repository 增加“缺失快照 starred repos”候选查询。
5. 将 `HomeView.reloadAfterSyncIfNeeded()` 中的首次 README 调度替换为 coordinator 触发。
6. 保留 `ReadmePrefetchPoller` / `RepoHealthPoller`，但首次 job 未完成时避免重复抢同一批候选。
7. 设置页按钮改名为“立即补齐 README”，动作接入 coordinator / README service 的手动补漏入口。
8. 状态窗口接入首次 warmup 状态。
9. 补充单测：状态机恢复、notFound 覆盖、限流暂停、缓存清理后覆盖率重算、completed 后不重置首次任务。

## 验收标准

- 新用户首次 starred 全量同步完成前，不启动首次 README / Health warmup。
- starred 全量同步完成后，首次 warmup 5 分钟后启动；用户点击“立即补齐 README”可提前 README 阶段。
- 应用在任意阶段关闭后，下次启动能继续而不是重头开始或丢失状态。
- 没有 README 的仓库不会阻止首次 README 阶段完成。
- GitHub 限流时任务暂停并可自动恢复。
- 清理 README 缓存不重置首次 completed 状态。
- Repo Health 首次阶段只补缺失快照，不处理 stale 快照。
- 周期性 poller 在首次 completed 后继续做兜底补漏。
