# RepoContext 分片管理 Checklist

> 状态：实施中
> 日期：2026-07-17
> 方案：`RepoContext分片管理实施方案.md`
> 约束：每个小功能独立使用中文 commit message 提交；不 push；每轮先提交审查报告，再修复报告发现的问题。

## 0. 开工与边界

- [x] 阅读根目录 `AGENTS.md`、`DESIGN.md` 与相关 UI / i18n 强制规范。
- [x] 只读检查 `docs/功能实现总览.md` 和 `docs/1-立项/开发前问题清单.md`。
- [x] 检查当前分支与未提交改动，确认不混入无关修改。
- [x] 确认不修改 v7 RAG schema，不把 RepoContext 写入 `rag_chunks`。
- [x] 确认本轮不改 `docs/功能实现总览.md`，不执行打包、发布、上传或 push。

## 1. 方案与清单

- [x] 固化 RepoContext 第二项展示、独立统计与普通分片边界。
- [x] 固化复用现有分片编辑 sheet 的编辑、校验、删除和下载交互。
- [x] 固化主动生成、真实阶段进度、取消和临时文件窄清理契约。
- [x] 固化生成/编辑/删除并发互斥与 repo 切换过期结果防护。
- [x] 新增并提交 `RepoContext分片管理实施方案.md`。
- [x] 新增并提交本 Checklist。

## 2. RepoContext 存储与编辑能力

- [x] 增加知识库浏览器所需的 RepoContext 快照读取能力。
- [x] 保存前解析 XML 并要求根节点为 `<repository>`。
- [x] 合法编辑使用 UTF-8 原子写入真实 `context.xml`。
- [x] 保存后同步刷新 metadata 的 token、字节数与访问时间。
- [x] 非法保存保持原文件不变并返回可展示错误。
- [x] 删除完整 RepoContext 项目产物，不写 tombstone。
- [x] 补齐读取、保存、校验、metadata 与删除单元测试。

## 3. 第二项展示与分片管理 UI

- [x] 有效 XML 作为特殊托管分片展示，不新增 `RAGChunkSource` 或数据库行。
- [x] RepoContext 固定插入元数据分片之后，成为第二项。
- [x] 普通分片排序、分页、embedding 与统计口径不变。
- [x] 详情页增加独立 RepoContext `0 / 1` 状态。
- [x] 点击 RepoContext 行复用 `KnowledgeRAGChunkEditor` sheet，不使用 popover。
- [x] 编辑器固定标题和路径，正文使用等宽字体。
- [x] 保存失败时 sheet 不关闭并展示校验/写入错误。
- [x] 行尾删除提供破坏性确认，生成期间禁用编辑和删除。
- [x] 补齐展示顺序、独立统计与交互 read model 测试。

## 4. XML 下载

- [x] 编辑 sheet header 增加 `square.and.arrow.down` 下载按钮。
- [x] `NSSavePanel` 限定 XML，默认文件名为 `<owner>-<repo>-context.xml`。
- [x] 导出当前编辑器草稿，包括未保存修改。
- [x] 下载不修改缓存和编辑器脏状态。
- [x] 用户取消静默返回，写入失败在 sheet 展示错误。
- [x] 补齐导出文件名、当前草稿与缓存不变测试。

## 5. 主动生成、进度与取消

- [x] 详情页增加“生成 / 重新生成 RepoContext XML”入口。
- [x] 复用 `AppDependencies.repoAIContextProvider`，不复制下载与打包实现。
- [x] 全局开关关闭时不静默修改设置，并提供前往 AI 设置的引导。
- [x] 状态机覆盖 resolving、downloading、packing、succeeded、failed、cancelled。
- [x] 展示真实阶段，不伪造无法测量的百分比。
- [x] 活动 spinner 在 hover / focus 时切换为 `stop.circle.fill`。
- [x] 点击停止取消 Task，并调用现有临时文件窄清理。
- [x] 取消保留正式 ZIP 与旧有效 XML，`CancellationError` 不显示为失败。
- [x] repo 切换和窗口关闭时取消旧任务并清理临时文件。
- [x] 生成期间阻止重复生成、编辑和删除。
- [x] 成功后立即刷新第二项，失败可重试。
- [x] 补齐状态映射、取消、缓存保留和过期结果防护测试。

## 6. i18n、文档与隐私

- [x] 所有新增固定文案进入 `Localizable.xcstrings`，en / zh-Hans 完整。
- [x] sheet 根视图挂 `.appLocaleEnvironment()`。
- [x] 所有 `.buttonStyle(.plain)` 按钮补 `.focusEffectDisabled()`。
- [x] 颜色只使用 `.primary` / `.secondary` 与明确状态色。
- [ ] 更新 `docs/3-设计/详细设计/30-本地RAG设计.md` 的 RepoContext 管理边界。
- [ ] 更新知识库 RAG 专项进度，但不伪造人工验收。
- [ ] 不修改 `docs/功能实现总览.md`；仅在报告中给出待确认同步草案。
- [ ] XML 不写 `rag_chunks`、embedding、CloudKit 或普通消息。

## 7. 自动化验证

- [ ] 新增 / 删除 Swift 文件后执行 `xcodegen generate`。
- [ ] RepoContext 存储与知识库浏览器定向测试通过。
- [ ] RAG 相关定向 Suite 通过。
- [ ] 全量 `StarcatTests` 通过。
- [ ] `Starcat` Debug build 通过。
- [ ] `StarcatDirect` Debug build 通过。
- [ ] `jq empty Starcat/Resources/Localizable.xcstrings` 通过。
- [ ] i18n 禁用 API 扫描通过。
- [ ] `git diff --check` 通过。
- [ ] 未新增 warning / error；既有问题单独记录，不冒充本需求回归。

## 8. 第一轮审查：架构、数据与取消边界

- [ ] 先新增并提交第一轮审查报告。
- [ ] 核对展示层投影没有污染数据库、embedding、分页和普通统计。
- [ ] 核对 Provider 复用、缓存键、保存、删除与 metadata 一致性。
- [ ] 核对生成状态、取消传播、临时清理和 repo 切换竞态。
- [ ] 核对 XML、私有仓库、CloudKit 与 Debug 隐私边界。
- [ ] 报告发现的问题逐个修复并按小功能提交。
- [ ] 修复后重新执行相关定向测试并回填报告。

## 9. 第二轮审查：UI、功能完整性与 i18n

- [ ] 先新增并提交第二轮审查报告。
- [ ] 核对第二项顺序、独立统计、生成入口与锁定状态。
- [ ] 核对编辑、校验失败不关闭、删除确认和重新生成闭环。
- [ ] 核对下载未保存草稿、默认文件名和错误展示。
- [ ] 核对进度阶段、hover / focus 停止、失败重试和生命周期取消。
- [ ] 核对 UI 规范、accessibility、tooltip、sheet locale 和双语文案。
- [ ] 报告发现的问题逐个修复并按小功能提交。
- [ ] 修复后重新执行相关定向测试并回填报告。

## 10. 第三轮审查：测试、文档与工程进度一致性

- [ ] 先新增并提交第三轮审查报告。
- [ ] 对照方案、代码、测试、i18n、专项进度和 Checklist 逐项检查。
- [ ] 只读核对 `docs/功能实现总览.md` 并起草待确认同步内容。
- [ ] 核对每个小功能、每轮报告和修复均有独立中文 commit。
- [ ] 执行最终定向测试、全量测试、双 target build 与静态检查。
- [ ] 报告发现的问题逐个修复并按小功能提交。
- [ ] 修复后再次执行最终门禁并回填报告。

## 11. 清洁复审与最终收口

- [ ] 至少三轮审查完成后新增并提交清洁复审报告。
- [ ] 清洁复审确认无遗留功能、测试、文档或一致性缺口。
- [ ] 本 Checklist 全部可自动验证项回填。
- [ ] 人工 UI 验收项明确列出，不伪造完成。
- [ ] 新增并提交 `RepoContext分片管理结果报告.md`。
- [ ] 结果报告列出实现、验证、提交、已知边界和工程总览待确认草案。
- [ ] 确认没有 push。
