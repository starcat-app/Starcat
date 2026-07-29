# 仓库洞察 XML 上下文 Checklist

> 状态：实施中
> 日期：2026-07-30
> 方案：`仓库洞察XML上下文实施方案.md`
> 约束：每个小功能独立中文规范提交；不 push；`docs/功能实现总览.md` 只读

## 0. 开工与边界

- [x] 只读检查 `docs/功能实现总览.md`、RAG 设计、洞察设计和开发前问题清单。
- [x] 核对当前分支、并行工作和未提交文件，建立本专项文件边界。
- [x] 创建并提交实施方案与 Checklist。
- [x] 确认不修改已发布 v7 RAG schema，不新增 `RAGChunkSource`。

## 1. 洞察结构化快照与 XML

- [x] 从 Prompt Provider 中拆出可复用的结构化洞察快照模型。
- [x] 保持页面、AI 与 Artifact 共用现有 Remote Provider、SQLite 和 Star History Repository。
- [x] 定义 `RepositoryInsightsDocument` 与 metadata。
- [x] 实现合法的 `<repository_insights>` 纯 XML Renderer。
- [x] XML 包含 repo identity、schema、生成时间、source hash 与数据新鲜度。
- [x] XML 包含 Release、发布节奏、健康度、OpenSSF、社区与安全聚合。
- [x] XML 包含 PR / Issue 活动统计与提交趋势。
- [x] XML 包含贡献者集中度及受控 Top Contributors。
- [x] XML 包含 Star 增长聚合与降采样趋势点。
- [x] 外部值全部 XML escape，不包含 Issue / PR 标题和安全公告正文。
- [x] XML hash、source hash 和趋势降采样结果稳定可复现。
- [x] 为结构化快照、Renderer、escape、hash 和 schema 补齐单元测试。

## 2. Artifact Storage 与生命周期

- [x] 实现独立 `RepositoryInsightsContextStorage`。
- [x] 使用 App Support 独立根目录，不污染 RepoContext 自选目录。
- [x] 原子写入 `insights.xml` 与 metadata。
- [x] 读取时验证 XML schema/root、repo identity 和 metadata。
- [x] source hash 未变化时零重复写盘。
- [x] 写入失败保留上一份有效 XML。
- [ ] 实现查看、导出和完整 Artifact 删除。
- [x] 删除不影响任何真实洞察 SQLite / Star History 数据。
- [x] 实现 deleted source hash 抑制，避免删除后立即重建。
- [x] 新 source hash 允许后台自动恢复。
- [x] 主动重新生成可忽略删除抑制。
- [x] 实现 repo-scoped Artifact single-flight。
- [x] 账号 / database scope 变化拒绝旧结果写入。
- [x] 补齐 Storage、删除抑制、原子性、single-flight 和账号边界测试。

## 3. 页面与仓库 AI 共用

- [x] 实现 `RepositoryInsightsContextCoordinator` 正常准备入口。
- [x] 实现 RAG 使用的 cache-only 准备 / 读取入口。
- [ ] 仓库洞察默认数据完成后后台生成 XML。
- [ ] 仓库洞察手动刷新成功后按新 source hash 更新 XML。
- [ ] 页面切仓 / 账号切换时拒绝迟到 Artifact 回写。
- [ ] AI 摘要使用同一 `RepositoryInsightsDocument.xml`。
- [ ] AI 对话使用同一 `RepositoryInsightsDocument.xml`。
- [ ] AI 先触发时同时预热洞察缓存并写入 XML。
- [ ] 页面后打开时复用 AI 已生成的数据和 Artifact。
- [ ] Tags-only 路径继续跳过洞察预热。
- [ ] 洞察 XML 不进入 AI 摘要 source hash。
- [ ] 自定义 Prompt 删除 `{insightsContext}` 时继续视为用户主动关闭注入。
- [ ] 补齐页面 / AI / 并发 / 零重复网络与零重复写盘测试。

## 4. 知识库特殊分片管理

- [ ] 抽取两个特殊上下文真正共用的联合展示能力，Storage 保持独立。
- [ ] 同时加载 Metadata、Insights XML、RepoContext XML 与普通分片。
- [ ] 固定顺序为 Metadata → Insights XML → RepoContext XML → 普通分片。
- [ ] 缺 Metadata 时特殊项置顶且 Insights 位于 RepoContext 之前。
- [ ] 单独显示 Insights `0 / 1` 和 RepoContext `0 / 1`。
- [ ] Insights XML 不计入普通分片数量、分页、embedding 与覆盖率。
- [ ] 洞察 XML 行复用现有分片密度和视觉语言。
- [ ] 点击打开只读 XML sheet，不提供编辑 / 保存。
- [ ] 支持复制与 XML 下载。
- [ ] 支持删除确认，删除只影响 Artifact。
- [ ] 支持主动生成 / 重新生成。
- [ ] 自动生成期间保留旧内容，不使用跳动式全页加载态。
- [ ] 切仓、移出知识库、筛选切仓和关窗取消主动任务。
- [ ] generation UUID + repo id + database scope 拒绝迟到结果。
- [ ] 补齐顺序、统计、只读、删除、生成、取消和迟到结果测试。

## 5. RAG Models、Service 与 Prompt

- [ ] 新增 Repository Insights RAG Document / Snapshot / Outcome。
- [ ] 新增 `RAGCitationSource.repositoryInsights`。
- [ ] 新增 `RAGHitKind.repositoryInsights`。
- [ ] 新增 `RAGContextUsageSegmentKind.repositoryInsights`。
- [ ] 新增可解释的执行步骤与 Debug stages。
- [ ] 不扩展 `RAGChunkSource`，不修改 v7 RAG schema。
- [ ] 显式仓库范围读取洞察 XML。
- [ ] 普通检索只读取最终保留 bundle 的洞察 XML。
- [ ] 多仓库读取有界并发，不扫描全知识库。
- [ ] RAG 缺 Artifact 时只允许 cache-only 本地生成，不额外联网。
- [ ] Builder 增加独立 `{repositoryInsightsSection}`。
- [ ] 洞察 XML 使用独立预算且服从总 Context Window。
- [ ] 实现洞察 XML 感知投影或整份移除，始终保持合法 XML。
- [ ] 洞察 XML 生成独立 citation，`chunkID = nil`。
- [ ] 洞察 XML 可作为真实仓库级证据通过证据门禁。
- [ ] 其它证据存在时洞察降级不阻断回答。
- [ ] Prompt 默认值迁移保留用户自定义模板。
- [ ] 补齐 Service、目标选择、预算、投影、citation、门禁和 Prompt 迁移测试。

## 6. RAG 全部可见面

- [ ] Plan Inspector 展示洞察目标、状态、时间、hash 和 token。
- [ ] 执行时间线展示真实 load / project / completed 状态。
- [ ] Context Tab 展示 Repository Insights 独立 token 分段。
- [ ] Evidence Inspector 展示洞察审计字段和 XML 预览。
- [ ] 支持 XML 全文、复制和 citation 定位。
- [ ] 洞察 citation 不显示普通“分片已删除”。
- [ ] Debug Trace 增加 request / load / projection 摘要。
- [ ] 专用 Debug stage 不重复保存 XML 正文。
- [ ] 最终 Prompt Debug 明确可能包含洞察 XML 的隐私边界。
- [ ] 会话只保存洞察审计 snapshot 和 citation。
- [ ] 历史只在 repo + sourceHash + xmlHash 匹配时回放 XML。
- [ ] 删除 / 更新后历史显示不可回放，不冒用新 XML。
- [ ] RAG Prompt 设置展示 `{repositoryInsightsSection}` 说明。
- [ ] 补齐 Plan、Timeline、Context、Evidence、Debug 和历史 round-trip 测试。

## 7. i18n、设计与正式文档

- [ ] 阅读并遵守 `DESIGN.md`、UI 与 i18n 规范。
- [ ] 新增文案全部提供 en + zh-Hans。
- [ ] 普通文本 / 图标只使用 `.primary` / `.secondary`。
- [ ] plain Button 补 `.focusEffectDisabled()`。
- [ ] sheet 使用 `SheetCloseButton` 并挂 `.appLocaleEnvironment()`。
- [ ] 刷新入口复用 `SyncIconButton` 或既有稳定行内状态。
- [ ] 更新 `docs/3-设计/详细设计/30-本地RAG设计.md`。
- [ ] 更新 `docs/3-设计/详细设计/49-洞察中心详细设计.md`。
- [ ] 更新知识库 RAG 专项进度文档或新增专项进度说明。
- [ ] 不修改 `docs/功能实现总览.md`，只在结果报告提供待确认草案。

## 8. 自动化与工程门禁

- [ ] 新增 / 删除 Swift 文件后执行 `xcodegen generate`。
- [ ] 洞察 Context / Storage 定向测试通过。
- [ ] Repository Insights 全部相关测试通过。
- [ ] Repo AI / AppSettings Prompt 测试通过。
- [ ] RepoContext Storage 回归测试通过。
- [ ] Knowledge RAG Core 与 Browser 相关测试通过。
- [ ] 全量 `StarcatTests` 通过，或明确记录非本需求阻塞证据。
- [ ] `Starcat` Debug build 通过。
- [ ] `StarcatDirect` Debug build 通过。
- [ ] `jq empty Localizable.xcstrings` 通过。
- [ ] String Catalog 格式与 en / zh-Hans 完整性通过。
- [ ] 禁用 i18n API 扫描通过。
- [ ] `git diff --check` 通过。
- [ ] 本专项文件无未提交残留。
- [ ] 并行工作文件未被误提交或回退。

## 9. 第一轮审查：架构、数据、性能

- [ ] 新增并提交第一轮审查报告。
- [ ] 审查单一真源、重复请求、重复缓存和重复 XML 渲染。
- [ ] 审查 source hash、XML hash、schema 与稳定性。
- [ ] 审查删除抑制、新数据恢复和主动重建语义。
- [ ] 审查账号切换、私有仓库和收藏且协作权限边界。
- [ ] 审查并发、取消、主线程 IO、多仓库读取和 token 上限。
- [ ] 修复第一轮全部 P0 / P1 / P2 问题并分别提交。
- [ ] 回填第一轮报告修复结果。

## 10. 第二轮审查：功能、RAG 全链路、UI

- [ ] 新增并提交第二轮审查报告。
- [ ] 审查 Knowledge Browser 所有展示、统计和操作。
- [ ] 审查 Planner / Service / Prompt / 门禁 / Citation 全链路。
- [ ] 审查 Plan / Timeline / Context / Evidence / Debug / 历史全部可见面。
- [ ] 审查 i18n、主题、focus、sheet、复制、删除和稳定加载状态。
- [ ] 审查 AI 摘要 / 对话与 RAG 是否消费同一 XML。
- [ ] 修复第二轮全部 P0 / P1 / P2 问题并分别提交。
- [ ] 回填第二轮报告修复结果。

## 11. 第三轮审查：测试、文档、进度一致性

- [ ] 新增并提交第三轮审查报告。
- [ ] 核对实现、测试、设计文档和专项进度逐项一致。
- [ ] 核对所有测试与双 target build 证据。
- [ ] 核对数据库 migration 和已发布数据兼容边界。
- [ ] 核对 Checklist 无虚假勾选，人工项与自动化项分离。
- [ ] 核对每个小功能独立中文提交且没有 push。
- [ ] 修复第三轮全部 P0 / P1 / P2 问题并分别提交。
- [ ] 回填第三轮报告修复结果。

## 12. 清洁复审与结果报告

- [ ] 新增并提交清洁复审报告。
- [ ] 清洁复审未发现新增 P0 / P1 / P2 功能缺口。
- [ ] 回填全部可自动验证的 Checklist。
- [ ] 未完成的人工 UI 验收明确保留，不伪造完成。
- [ ] 新增仓库洞察 XML 上下文结果报告。
- [ ] 结果报告包含功能、架构、测试、审查、提交、工作区与未 push 状态。
- [ ] 结果报告提供 `docs/功能实现总览.md` 待确认同步草案。
- [ ] 最终结果报告单独提交。
