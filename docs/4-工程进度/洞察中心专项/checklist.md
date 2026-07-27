# 洞察中心与仓库星标历史专项 Checklist

> 状态：进行中（前端 Mock UI 已完成，真实数据 Provider / 数据库 / API 尚未实施）
>
> 创建：2026-07-27
>
> 主方案：[`49-洞察中心详细设计.md`](../../3-设计/详细设计/49-洞察中心详细设计.md)
>
> 数据专项：[`50-仓库星标历史整体落地方案.md`](../../3-设计/详细设计/50-仓库星标历史整体落地方案.md)
>
> 原型：[`我的洞察.png`](../../3-设计/原型/我的洞察.png) / [`仓库洞察.png`](../../3-设计/原型/仓库洞察.png)
>
> 涉及仓库：Starcat 主项目 `dev`、`supports/starcat-discovery-api` `dev`
>
> 提交约束：每完成一个可独立验收的小功能立即提交；使用中文 commit message；禁止 push

---

## 0. 执行规则

### 0.1 硬性流程

- [ ] 开工前记录 Starcat 与 `starcat-discovery-api` 的 branch、HEAD、worktree 和 dirty 状态，保留所有无关改动。
- [x] 开工前只读检查 `docs/功能实现总览.md`、`DESIGN.md`、相关 UI / i18n 规范及两份详细设计。
- [ ] 每个小功能必须同时完成“代码 + 必要测试 + 必要文档”，验证通过后立即提交，禁止积攒多个独立功能后一次提交。
- [ ] 每个 commit 必须符合 `<type>(<scope>): <中文摘要>`，scope 使用 `insights`、`star-history` 或 `discovery` 等稳定产品域。
- [ ] 每次提交前运行与切片风险相匹配的定向测试和 `git diff --check`。
- [ ] Starcat 主项目与 `supports/starcat-discovery-api` 是两个独立 Git 仓库，分别提交、分别核对提交历史。
- [ ] 全程不执行 `git push`，不创建 PR，不发布 tag。
- [ ] 未经 dong4j 另行明确授权，不执行测试环境或生产环境部署、Fly secrets 修改、BigQuery 付费查询或发布脚本。
- [ ] 未经 dong4j 明确说“同步总览 / 可以写总览”等，不修改 `docs/功能实现总览.md`。
- [ ] 未经 dong4j 明确授权，不修改四份 Changelog；“开干 / 提交”不等于 Changelog 授权。
- [ ] 新增或删除 Swift 文件后必须运行 `xcodegen generate`。
- [ ] 运行 `xcodebuild test` 前必须关闭 Xcode IDE，避免抢占 `testmanagerd`。

### 0.2 审查与修复顺序

- [ ] 每轮审查必须先新增一份审查报告并提交，报告中固定 findings 编号、证据、等级和修复要求。
- [ ] 审查报告提交后才能开始修复；禁止先修代码再补写“事后审查报告”。
- [ ] 每个可独立回滚的 finding 单独修复、验证并提交；同一根因的代码与测试可以同一提交。
- [ ] 修复后回填该轮报告的 commit hash、验证命令和关闭结论，并单独提交报告闭环。
- [ ] 若复审继续发现问题，新增下一轮报告，不覆盖或重写前一轮证据。
- [ ] 至少完成五个专项维度审查和两轮连续无新增未关闭 P0 / P1 / P2 的最终复审。
- [ ] 只有代码、测试、设计文档、专项 Checklist、审查报告、提交历史和工作区状态全部一致，才能新增结果报告。

---

## 1. 产品范围与不可变决策

- [x] “洞察”作为与管理、趋势、活动同级的顶级入口，继续使用 Starcat 现有三栏框架。
- [x] “我的洞察”支持“全部收藏 / 知识库”两个明确范围，禁止不同卡片静默混用统计口径。
- [x] “仓库洞察”属于 Manage 仓库详情，在现有 `RepoDetailScaffold` body 中提供 `README / 洞察` 切换。
- [x] Star 历史只作为仓库洞察中的“Star 趋势”区块，不新增 Hero action、独立 Sheet 或第四种详情模式。
- [ ] Star 趋势使用 `3 月 / 1 年 / 全部`独立范围；PR / Issue / Commit 使用 `1 周 / 1 月 / 3 月 / 1 年`活动范围。
- [x] Star 长期历史明确区分“估算 · GH Archive”和“Starcat 精确快照”，不得用“精确历史”误导。
- [ ] 私有仓库不把 repo 信息发送到 `starcat-discovery-api`，只显示本机精确快照。
- [x] Traffic / Views / Clones / Referrers 不进入首版通用仓库洞察。
- [ ] 我的洞察使用实时 SQLite 聚合，不新增 summary 表或定时任务。
- [ ] 仓库洞察远端缓存与 Star 历史点共用一次追加迁移，但保持两张职责单一的表。
- [ ] 不修改已发布的 `v1-initial`；当前基线为 `v15` 时追加 `v16-repository-insights`。
- [ ] 不新增第三个后端服务；Star 长期历史扩展现有 `starcat-discovery-api`。

---

## 2. 文档基线与数据可行性门槛

### 2.1 方案和现状基线

- [x] 两张原型已归档到 `docs/3-设计/原型/`。
- [x] 已新增洞察中心详细设计并合并仓库星标历史。
- [x] 已新增仓库星标历史整体落地方案。
- [x] 已确认 `starcat-discovery-api` 的生产 ingest 链路已经调用 `RecordDailySnapshot`，后续只需保留并补回归，禁止重复实现。
- [ ] 开工时重新核对 `SidebarRootPage`、`HomeViewModel.refreshSidebar()`、`GlobalRepoFilterState`、`ManageDetailContent`、`RepoDetailScaffold` 和当前最新 migration。
- [ ] 开工时重新核对 `starcat-discovery-api` 的 store、ingest、router、scheduler、鉴权、缓存和 migration 机制。
- [ ] 对两份方案逐条建立“需求 → 代码位置 → 测试 → commit → 验收证据”追踪矩阵。

### 2.2 M0：GH Archive 可行性 Spike

- [ ] 明确 BigQuery 凭据来源、只读权限、预算和 `maximumBytesBilled`；未经授权不产生付费查询。
- [ ] 选择小、中、大各 2 个公开仓库，以稳定 GitHub repo ID 查询 `WatchEvent`。
- [ ] 验证 GH Archive 当前表名、字段类型、覆盖起点、查询耗时、扫描字节和缺口。
- [ ] 对比累计 `WatchEvent`、当前 `stargazers_count` 与归一化曲线。
- [ ] 验证 `totalEvents == 0`、仓库改名 / 转移、归档仓库和超大仓库边界。
- [ ] 输出 M0 GO / NO-GO 结论和成本上限，写入新增审查报告或专项决策文档。
- [ ] M0 GO 时确认继续实现 GH Archive 估算；NO-GO 时同步收缩 49 / 50 号方案为“从 Starcat 开始记录”，禁止上线伪精确曲线。

计划提交：

- [ ] `docs(star-history): 记录星标历史数据可行性结论` — 实际 commit：`待回填`

---

## 3. M1：我的洞察数据闭环

### 3.1 领域模型与一致快照

- [x] 新增 `InsightsScope`、分布项、操作项、覆盖摘要和 `MyInsightsSnapshot` 领域模型。
- [ ] 新增 `MyInsightsSnapshotProviding`，在一次一致数据库读取中返回当前范围完整快照。
- [ ] 提取或复用 `KnowledgeBaseMetadataSnapshot` 已验证的 SQL 口径，避免 UI 与 RAG Prompt 各写一套统计。
- [ ] 明确收藏范围 `is_starred = 1` 与知识库范围 `library_state = in_library`。
- [ ] 状态聚合使用 `LEFT JOIN repo_notes`，缺失 note 行必须计入 `unread`。
- [ ] “已整理”按标签、笔记、AI 笔记和状态派生，不持久化新字段。
- [ ] 语言分布保留“未知”，前 8 名以外合并为“其他”。
- [x] Health 与 OpenSSF 覆盖范围必须在标题和模型中显式表达。
- [ ] Snapshot 支持数据库 revision + 最多 60 秒内存缓存；滚动 30 天数据不得无限复用。

计划提交：

- [ ] `feat(insights): 建立我的洞察统计快照` — 实际 commit：`待回填`
- [ ] `test(insights): 覆盖洞察范围与状态统计口径` — 实际 commit：`待回填`
- [x] `feat(insights): 建立洞察前端 Mock 数据契约` — 实际 commit：`c501ab6b`

### 3.2 “需要处理”聚合

- [ ] 聚合未打标签、未读、无 README、无可索引内容、索引失败 / 过期和 Health 待计算。
- [ ] 全部收藏范围隐藏知识库专属 RAG 噪音，并提供切换知识库提示。
- [x] 每个 action item 保存稳定筛选语义和可访问描述，不在 View 中临时拼规则。
- [ ] 覆盖零值、数据缺失、索引模型变化和 active scope 非收藏仓库。

计划提交：

- [ ] `feat(insights): 增加洞察待处理统计` — 实际 commit：`待回填`

---

## 4. M1～M2：我的洞察三栏 UI 与下钻

### 4.1 顶级导航和三栏状态

- [x] 为 `SidebarRootPage` 增加 `insights`，补齐 title、icon、selection 和恢复逻辑。
- [x] 在 `HomeView` 注册洞察三栏路由，不用根级条件分支替换现有 `NavigationSplitView`。
- [x] Sidebar 提供概览、整理情况、技术分布、项目健康四个主题。
- [x] 中栏提供主题摘要和待处理集合，使用原生轻量 source-list row。
- [x] Detail 展示范围、KPI、整理情况、技术分布、需要处理和覆盖进度。
- [x] 离开并返回洞察时恢复主题、范围和中栏选择，不保存滚动位置。
- [ ] 刷新统一使用 `SyncIconButton`，只重读本地数据库，不触发全量 Stars 同步。
- [ ] loading、empty、error、stale 保持稳定内容树，不闪回其他页面数据。

计划提交：

- [x] `feat(insights): 添加洞察中心三栏导航` — 实际 commit：`19ce6c25`
- [x] `feat(insights): 实现我的洞察概览页面` — 实际 commit：`b5926f34`
- [ ] `feat(insights): 补齐洞察主题与待处理列表` — 实际 commit：`待回填`

### 4.2 结构化下钻

- [ ] 扩充 `GlobalRepoFilterState` 的标签、README、可索引内容和 RAG index state 筛选。
- [ ] 所有洞察下钻从 `.neutral` 构造，禁止继承用户此前隐藏的过滤条件。
- [ ] 复用 `applyTemporaryGlobalFilters(...)`，切换到 Manage 后建立临时筛选会话。
- [ ] 清除临时筛选时恢复点击前状态，并提供返回洞察上下文。
- [ ] 数字入口与下钻列表条数必须一致，禁止用搜索关键字模拟结构化筛选。
- [ ] 覆盖状态、语言、未打标签、README、RAG、Health 和组合筛选回归。

计划提交：

- [ ] `feat(insights): 支持洞察统计下钻仓库列表` — 实际 commit：`待回填`
- [ ] `test(insights): 覆盖洞察下钻与筛选恢复` — 实际 commit：`待回填`

---

## 5. 统一 v16 迁移与本地缓存

### 5.1 迁移

- [ ] 在实施当日重新确认最新 migration 仍为 `v15`；若已变化，使用真实下一顺序版本并同步两份方案。
- [ ] 追加 `v16-repository-insights`，禁止修改任何已发布 migration。
- [ ] 新增 `repo_insights_snapshots`，主键覆盖 `repo_id + dataset + range_key`。
- [ ] 新增 `repo_star_history_points`，主键覆盖 `repo_id + observed_on + source`。
- [ ] 两表通过 repo 外键级联清理，不进入 CloudKit 和用户 JSON 导入导出。
- [ ] 增加 v15 → v16 升级测试、空库迁移测试、重复迁移测试和既有用户数据不变验证。

计划提交：

- [ ] `feat(insights): 新增仓库洞察统一缓存迁移` — 实际 commit：`待回填`
- [ ] `test(insights): 覆盖洞察缓存数据库升级` — 实际 commit：`待回填`

### 5.2 通用仓库洞察缓存

- [ ] 新增 `RepositoryInsightsCache` 和 GRDB Record / Repository。
- [ ] 支持 dataset、range、payload、ETag、fetchedAt、staleAfter 和 default branch SHA。
- [ ] 实现 15 分钟活动缓存和 24 小时统计 / contributors / community 缓存。
- [ ] 支持 stale-while-refresh：有旧缓存时刷新失败不清空旧值。
- [ ] repo 删除后缓存级联清理；损坏 payload 只丢弃对应 dataset。

计划提交：

- [ ] `feat(insights): 实现仓库洞察本地缓存` — 实际 commit：`待回填`

---

## 6. M3：仓库洞察本地闭环

### 6.1 README / 洞察切换

- [x] 将 `ManageDetailContent` 扩展为 Manage 专用内容容器，保持 `RepoDetailScaffold` 头部和 Metadata 职责不变。
- [x] 在 Manage body 顶部增加 `README / 洞察`分段控件。
- [ ] 主窗口与独立详情窗口复用同一内容容器和 scene-scoped selection。
- [x] 切换到洞察时不保活不可见 README `WKWebView`，避免双重重型视图。
- [x] 切换模式不丢仓库选择，不破坏 Hero 折叠、README 滚动和详情窗口依赖注入。

计划提交：

- [x] `feat(insights): 增加仓库详情洞察模式` — 实际 commit：`0cf1000a`
- [ ] `test(insights): 覆盖仓库详情模式切换` — 实际 commit：`待回填`

### 6.2 本地区块

- [ ] 新增 `RepositoryInsightsView` 和 `RepositoryInsightsViewModel`。
- [ ] 先显示本地 Release、四维 Health、OpenSSF、License 和 Community 已缓存信息。
- [ ] 各区块独立 loading / empty / unavailable / failed，单一区块失败不切整页错误态。
- [ ] 快速切换 repo 时以 `repo.id + generation` 丢弃旧结果。
- [ ] Detail 宽度变化时一列 / 两列自适应，不设置固定 Detail 最小宽度。

计划提交：

- [ ] `feat(insights): 展示仓库洞察本地指标` — 实际 commit：`待回填`
- [x] `feat(insights): 展示仓库活动与健康指标（Mock）` — 实际 commit：`06423e83`

---

## 7. M4：类型化 GitHub 仓库指标

### 7.1 Client 抽取

- [ ] 从 RAG Remote Context 中提取共享认证、API version、URL、Rate Limit 和状态码处理。
- [ ] 新增 `GitHubRepositoryMetricsClient`，返回类型化 DTO / 领域模型，不返回面向 LLM 的文本。
- [ ] RAG Remote Context 改为类型化 Client 的消费者，行为和审计契约保持不变。
- [ ] 支持 Search Issues、commit activity、contributors 和 community profile。
- [ ] `202`、`403`、`429`、`404`、`422`、`Retry-After` 和 rate reset 映射为稳定错误。
- [ ] 远端请求串行或低并发执行，避免触发 secondary rate limit。

计划提交：

- [ ] `refactor(insights): 提取类型化 GitHub 仓库指标客户端` — 实际 commit：`待回填`
- [ ] `test(insights): 覆盖 GitHub 指标错误与限流` — 实际 commit：`待回填`

### 7.2 活动与社区数据

- [ ] 实现新建 / 合并 PR、新建 / 关闭 Issue 的时间范围查询。
- [ ] 实现最近 52 周 Commit activity，并在客户端按范围裁剪。
- [ ] 实现 contributors、community profile 和最近活动时间线。
- [ ] Activity range 使用 `1 周 / 1 月 / 3 月 / 1 年`，不会改变 Star 趋势范围。
- [ ] 有缓存时先显示；刷新按钮防重复点击；离线和限流保留旧数据。
- [ ] 无登录时仍显示本地 Health / OpenSSF，远端区块提供可理解提示。

计划提交：

- [ ] `feat(insights): 加载仓库协作活动指标` — 实际 commit：`待回填`
- [ ] `feat(insights): 展示贡献者与社区规范` — 实际 commit：`待回填`
- [ ] `feat(insights): 增加仓库最近活动时间线` — 实际 commit：`待回填`

---

## 8. M4：`starcat-discovery-api` 星标历史

### 8.1 后端存储与模型

- [ ] 新增独立 `repo_star_history_cache`，不把任意用户仓库写入 Discovery catalog。
- [ ] 状态只允许 `building / ready / failed`，保存 repo ID、full name、当前 Stars、覆盖起点、points、生成时间、过期时间和错误摘要。
- [ ] 同 repo 构建任务去重，服务重启后过期 building 可重新入队。
- [ ] 保留现有 `repo_daily_snapshots` 和生产 `RecordDailySnapshot` 调用，补防回退测试。

计划提交（`starcat-discovery-api`）：

- [ ] `feat(star-history): 新增仓库星标历史缓存` — 实际 commit：`待回填`
- [ ] `test(star-history): 保护每日快照生产链路` — 实际 commit：`待回填`

### 8.2 Provider、归一化和降采样

- [ ] 新增可测试替换的历史事件 Provider 协议。
- [ ] 实现 BigQuery / GH Archive provider，使用参数化 repo ID、日期和最大扫描预算。
- [ ] 实现日累计、当前 Stars 归一化、`totalEvents == 0` 和末点校准。
- [ ] 估算段保持单调，精确快照段允许真实下降。
- [ ] 实现 `3m` 日、`1y` 周、`all` 月降采样，首末点与来源不丢失。
- [ ] 每个序列最多 500 点，输出 coverageStart、generatedAt、source 和 precision。

计划提交（`starcat-discovery-api`）：

- [ ] `feat(star-history): 实现 GH Archive 历史提供器` — 实际 commit：`待回填`
- [ ] `feat(star-history): 实现星标历史归一化` — 实际 commit：`待回填`
- [ ] `feat(star-history): 增加星标历史范围降采样` — 实际 commit：`待回填`

### 8.3 异步构建与 API

- [ ] 首次 miss 写 building 并进入有界 worker queue，HTTP 立即返回 `202 + Retry-After`。
- [ ] worker 并发、超时、每日预算和 negative cache 可配置。
- [ ] 新增 `GET /api/v1/repos/{owner}/{repo}/star-history`。
- [ ] 必填 `repo_id`，后端校验 owner/name 与 ID，二次确认公开仓库。
- [ ] 支持 `3m / 1y / all`、ETag、`If-None-Match`、Cache-Control 和统一 envelope。
- [ ] 固定 `400 / 401 / 404 / 409 / 422 / 429 / 503` 错误语义。
- [ ] 日志不记录用户 token、Star 列表或访问顺序。
- [ ] 更新 README / README-ZH、API 文档和环境变量说明。

计划提交（`starcat-discovery-api`）：

- [ ] `feat(star-history): 实现星标历史异步构建` — 实际 commit：`待回填`
- [ ] `feat(star-history): 提供仓库星标历史接口` — 实际 commit：`待回填`
- [ ] `test(star-history): 覆盖星标历史缓存与异常路径` — 实际 commit：`待回填`
- [ ] `docs(star-history): 补充星标历史接口说明` — 实际 commit：`待回填`

---

## 9. M3～M4：Starcat 星标历史客户端

### 9.1 本机精确快照

- [ ] 新增 `StarHistorySource`、`StarHistoryPrecision`、`StarHistoryPoint` 和 GRDB Record。
- [ ] 在 Stars 全量同步、手动同步和单仓库 metadata 成功落库后按 UTC 日期幂等记录快照。
- [ ] 只消费已经成功取得的 metadata，不能为了写快照额外请求 GitHub。
- [ ] 远端刷新只替换 `gh_archive / discovery_snapshot`，不得删除 `local_snapshot`。
- [ ] repo 删除时历史点级联清理；不进入 CloudKit 和用户数据导入导出。

计划提交：

- [ ] `feat(star-history): 记录仓库每日星标快照` — 实际 commit：`待回填`
- [ ] `test(star-history): 覆盖本机星标快照幂等性` — 实际 commit：`待回填`

### 9.2 API、Repository 与状态

- [ ] 新增 `StarHistoryAPI`，处理 DTO、ETag、`202`、错误映射和私有仓库拦截。
- [ ] 新增 `RepoStarHistoryRepository`，cache-first 合并远端估算、Discovery 快照和本机快照。
- [ ] 同日精确点优先于估算点；当前 metadata 更新时补今天快照。
- [ ] 远端失败返回 stale cache；私有仓库绝不调用 API。
- [ ] 新增 `StarHistoryViewModel`，支持独立范围、generation、取消、有界轮询和增长派生。
- [ ] `202` 最多自动轮询三次，之后停止并提供手动刷新。

计划提交：

- [ ] `feat(star-history): 接入仓库星标历史服务` — 实际 commit：`待回填`
- [ ] `feat(star-history): 合并估算与精确星标快照` — 实际 commit：`待回填`
- [ ] `test(star-history): 覆盖历史合并与请求取消` — 实际 commit：`待回填`

### 9.3 Star 趋势区块

- [x] 新增 `StarHistorySection`、Summary、SourceBadge 和 Swift Charts 折线。
- [x] 展示当前 Stars、30 天增长、1 年增长、覆盖起点、更新时间和精度说明。
- [x] 使用 `3 月 / 1 年 / 全部`独立范围，不被活动 range 修改。
- [x] 估算段与快照段使用同一主色、不同线型或透明度。
- [ ] hover / RuleMark 不是唯一读数入口，VoiceOver 可读日期、数量、增量、来源和精度。
- [ ] 覆盖首次加载、有缓存刷新、building、离线、远端失败、单快照、私有仓库和无数据。
- [x] Star 趋势位于活动 KPI 后、Commit activity 前，不打开 Sheet。

计划提交：

- [x] `feat(star-history): 展示仓库 Star 趋势` — 实际 commit：`25db02da`
- [ ] `test(star-history): 覆盖 Star 趋势状态与范围` — 实际 commit：`待回填`

---

## 10. M5：视觉、国际化与辅助功能

- [ ] 新增 `insights.*` 与 `repo.starHistory.*` String Catalog key，保持 `"key" : value` 格式且不整文件重排。
- [ ] 补齐 en / zh-Hans；按项目 18 Locale 流程导出或同步 translation packages。
- [x] 新增 Swift 调用不使用 `String(localized:)` 或 `NSLocalizedString`。
- [x] 文字和图标只用 `.primary / .secondary`，禁止无说明 `.tertiary`。
- [x] 所有 `.buttonStyle(.plain)` 同时 `.focusEffectDisabled()`。
- [x] 刷新入口统一使用 `SyncIconButton`。
- [ ] 图表和状态颜色适配 Light / Dark、Increase Contrast 和 Reduce Motion。
- [x] 最小窗口和窄 Detail 下使用单列，不增加固定 Detail minWidth。
- [ ] 长仓库名、大数值、空值、RTL 和较长 Locale 不破版。
- [ ] 为 KPI、分布、图表、筛选、错误和更新时间补 VoiceOver 汇总语义。
- [x] 使用真实运行截图对照两张原型；允许数据与文案变化，不允许脱离 Starcat 三栏结构。

计划提交：

- [x] `improve(insights): 完善洞察布局与窗口适配` — 实际 commit：`0f929a61`
- [ ] `feat(insights): 补齐洞察国际化与辅助功能` — 实际 commit：`待回填`

---

## 11. 自动化测试、构建与人工验收

### 11.1 Starcat 定向测试

- [ ] Snapshot 范围、缺失 note = unread、已整理、语言与 coverage。
- [ ] 待处理项、下钻筛选和临时状态恢复。
- [ ] v15 → v16 migration、缓存 TTL、损坏 payload 和 repo 级联清理。
- [ ] GitHub Metrics DTO、Search qualifier、`202 / 403 / 429 / 404 / 422`。
- [ ] RepositoryInsightsViewModel 的 repo / range generation 和取消。
- [ ] 本机 Star 快照、远端替换、同日精确优先、负增长和范围降采样。
- [ ] 私有仓库不访问历史 API、building 有界轮询、stale fallback。
- [ ] 主详情与独立详情窗口复用一致。

### 11.2 `starcat-discovery-api` 自动化

- [ ] 运行 `make check`，覆盖 fmt、vet、race test 和 coverage。
- [ ] 运行 `go build ./...` 或等价构建。
- [ ] 覆盖 WatchEvent 日累计、零事件、归一化、舍入单调、降采样和末点。
- [ ] 覆盖缓存 hit / stale / failed / building、并发任务去重和服务重启恢复。
- [ ] 覆盖公开性校验、repo ID mismatch、私有拒绝、预算超限和 provider 失败。
- [ ] 覆盖 `200 / 202 / 304 / 400 / 401 / 404 / 409 / 422 / 429 / 503` contract fixture。

### 11.3 Starcat 全量验证

- [x] 关闭 Xcode IDE。
- [x] 运行 `xcodegen generate`。
- [ ] 运行全部 `StarcatTests`；任何失败都先与基线对照，禁止把未知失败直接写成“既有问题”。
- [x] 运行 Debug build。
- [x] 校验 `Localizable.xcstrings` 为合法 JSON。
- [ ] 运行 i18n、颜色、Focus Ring、迁移和 `git diff --check` 静态检查。

### 11.4 人工 UI 验收

- [x] 验收“洞察”顶级入口、Sidebar、中栏和 Detail 的选择恢复。
- [x] 验收全部收藏 / 知识库切换无上一范围数据闪烁。
- [ ] 验收每个“需要处理”数字与下钻列表条数一致。
- [x] 验收 README / 洞察切换、Hero 折叠和 README 滚动无回归。
- [ ] 验收主窗口与独立详情窗口行为一致。
- [x] 验收 Star 趋势来源、精度、覆盖起点、更新时间和增长读数。
- [ ] 验收 loading、empty、stale、offline、rate-limited、building、private 和 failed。
- [ ] 验收 Light / Dark、最小窗口、长文案、RTL、Reduce Motion 和 VoiceOver。
- [x] 将真实验收步骤和截图证据写入 `验收步骤说明.md`；无法由自动化观察的项目保持人工待验收，不伪造完成。

计划提交：

- [ ] `test(insights): 补齐洞察中心集成回归` — 实际 commit：`待回填`
- [x] `docs(insights): 新增洞察中心验收步骤` — 实际 commit：`64e49e69`

---

## 12. 文档与工程进度同步

- [ ] 将 49 号文档从“方案待确认”更新为真实实现状态，回填最终文件、迁移、缓存、错误和范围契约。
- [ ] 将 50 号文档回填最终 M0 结论、Discovery API、客户端合并和 Star 趋势实现。
- [ ] 修正实施中发现的所有过时现状，不保留已废弃的类名、表名、入口或测试数字。
- [ ] 更新详细设计 README 索引描述。
- [ ] 同步 `starcat-discovery-api` README / README-ZH / API / 配置文档。
- [x] 新增专项 `验收步骤说明.md`。
- [ ] 只读核对 `docs/功能实现总览.md`；未获单独授权时，在审查报告中给出拟同步 checkbox、`> 实现：`、仪表盘和变更日志内容，不直接修改。
- [ ] 核对 Changelog 授权状态；未获授权时不修改，在结果报告中明确是否建议写入当前待发布版本。
- [ ] Checklist 每个已完成项必须有代码、测试、文档、commit 或审查报告证据，禁止仅凭“看起来完成”勾选。

计划提交：

- [ ] `docs(insights): 回填洞察中心实现文档` — 实际 commit：`待回填`

---

## 13. 多轮审查与报告

### 13.1 第一轮：需求、文档与 Checklist 完整性

- [ ] 新增 `审查报告-01-需求文档与Checklist完整性.md`，提交后再修复。
- [ ] 对照两张原型、49 / 50 号方案和本 Checklist，检查需求遗漏、冲突、非目标和追踪矩阵。
- [ ] 核对已实现代码是否覆盖所有首期区块，没有模拟数据或空壳入口。
- [ ] 逐项修复发现并独立提交。
- [ ] 回填报告 findings 闭环和 commit 证据。

### 13.2 第二轮：数据库、后端、API、隐私与成本

- [ ] 新增 `审查报告-02-数据库后端API隐私与成本.md`，提交后再修复。
- [ ] 审查 v16 append-only migration、外键、TTL、事务、损坏缓存和既有用户升级。
- [ ] 审查 GH Archive provider、归一化、降采样、预算、worker、缓存和 API contract。
- [ ] 审查私有仓库、日志、token、CloudKit、JSON 导入导出和部署配置边界。
- [ ] 逐项修复发现并独立提交。
- [ ] 回填报告 findings 闭环和 commit 证据。

### 13.3 第三轮：代码架构、并发、缓存与失败路径

- [ ] 新增 `审查报告-03-代码架构并发缓存与失败路径.md`，提交后再修复。
- [ ] 审查 View / ViewModel / Repository / Client 职责和依赖注入。
- [ ] 审查 repo / range generation、取消、旧响应、SWR、Rate Limit 和 `202` 轮询。
- [ ] 审查 RAG 共享 Client 行为未回归、Star 历史与活动状态互不污染。
- [ ] 逐项修复发现并独立提交。
- [ ] 回填报告 findings 闭环和 commit 证据。

### 13.4 第四轮：UI、交互、国际化与辅助功能

- [ ] 新增 `审查报告-04-UI交互国际化与辅助功能.md`，提交后再修复。
- [ ] 对照 DESIGN.md、UI 强制规范和真实运行截图。
- [ ] 审查三栏密度、最小窗口、README 切换、Star Chart、明暗主题、RTL 和长文案。
- [ ] 审查 plain button、Focus Ring、刷新、语义色、Reduce Motion 和 VoiceOver。
- [ ] 逐项修复发现并独立提交。
- [ ] 回填报告 findings 闭环和 commit 证据。

### 13.5 第五轮：测试、构建、文档、工程进度与提交历史

- [ ] 新增 `审查报告-05-测试构建文档工程进度与提交一致性.md`，提交后再修复。
- [ ] 重跑两个仓库定向测试、全量测试、构建和静态检查。
- [ ] 对照代码回读 49 / 50、API 文档、验收步骤和 Checklist。
- [ ] 只读核对 `docs/功能实现总览.md`，记录已授权同步或拟同步内容。
- [ ] 审计两个仓库 commit：中文、格式正确、单一主题、无夹带、无 push。
- [ ] 逐项修复发现并独立提交。
- [ ] 回填报告 findings 闭环和 commit 证据。

### 13.6 连续无问题最终复审

- [ ] 新增 `审查报告-06-最终复审.md`，确认无新增未关闭 P0 / P1 / P2。
- [ ] 再从零对照原型、方案、代码、测试、文档和 Checklist，不仅复读第五轮结论。
- [ ] 若发现问题，先提交本轮报告，再修复并新增下一轮报告，编号继续递增。
- [ ] 至少取得两轮连续“无新增未关闭 P0 / P1 / P2”；第二轮命名为 `最终复审报告.md` 或下一顺序审查报告。
- [ ] 最终复审再次运行关键自动化矩阵，刷新测试数字和 commit 证据。

每轮固定提交：

- [ ] `docs(insights): 新增第N轮洞察中心审查报告` — 每轮实际 commit：`待逐轮回填`
- [ ] 审查发现修复：按 finding 独立使用 `fix / improve / test / docs` 提交 — 实际 commit：`待逐项回填`
- [ ] `docs(insights): 回填第N轮审查修复闭环` — 每轮实际 commit：`待逐轮回填`

---

## 14. 最终结果报告与完成定义

### 14.1 结果报告

- [ ] 所有适用 Checklist 项已勾选，所有 commit hash、测试数字和报告链接已回填。
- [ ] 新增 `docs/4-工程进度/洞察中心专项/结果报告.md`。
- [ ] 报告分开说明：已实现功能、数据与隐私边界、测试证据、审查闭环、文档状态、未执行的外部授权动作和明确非目标。
- [ ] 报告列出 Starcat 与 `starcat-discovery-api` 的基线、最终 HEAD、提交数量、最新提交和未 push 证据。
- [ ] 报告不得把未获授权的总览、Changelog、部署、合并或 push 写成已完成。

计划提交：

- [ ] `docs(insights): 新增洞察中心专项结果报告` — 实际 commit：`待回填`

### 14.2 最终机器证据

- [ ] Starcat 专项测试全部通过。
- [ ] Starcat 全量测试无未解释的非预期失败。
- [ ] Starcat Debug build 成功。
- [ ] `starcat-discovery-api make check` 与构建通过。
- [ ] 两个仓库 `git diff --check` 通过。
- [ ] `Localizable.xcstrings` 与相关 JSON fixture 合法。
- [ ] 两个仓库工作区 clean，或只剩明确不属于本需求且已在报告列出的用户改动。
- [ ] 两个仓库均未 push；本地分支领先数量和提交历史已记录。
- [ ] Checklist 中不存在未说明的 `[ ]`，不存在无证据的 `[x]`。

### 14.3 完成判定

- [ ] “我的洞察”所有数字有唯一口径，并能下钻到数量一致的 Manage 列表。
- [ ] “仓库洞察”完整提供 Star 趋势、活动 KPI、Commit、贡献者、Health、社区、安全和最近活动。
- [ ] Star 历史估算与精确快照来源明确，私有仓库完全本地。
- [ ] README / 洞察切换、主窗口和独立详情窗口无功能缺失。
- [ ] 所有错误、离线、限流、构建中、空数据和快速切仓路径有实现与测试。
- [ ] 文档描述、工程进度、Checklist、代码、API 和实际测试结果一致。
- [ ] 多轮审查没有未关闭 P0 / P1 / P2，且最后两轮没有新增问题。
- [ ] 结果报告已提交。

---

## 15. 不计入自动完成的外部授权动作

以下动作不因“实现完成”而自动获得授权，也不能为追求 Checklist 全勾而擅自执行：

1. 配置或修改 BigQuery / GCP 付费资源与凭据。
2. 修改 Fly secrets。
3. 部署 `starcat-discovery-api` 测试或生产环境。
4. 修改 `docs/功能实现总览.md`。
5. 修改四份 Changelog。
6. 合并分支、push、创建 PR、tag、打包、上传或发布。

最终审查与结果报告必须记录这些动作的真实授权和执行状态；未授权时明确列为“外部交付动作未执行”，不把它误报成功，也不把它混同为代码功能缺失。
