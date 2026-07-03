# Starred 与知识库 PR1-PR9 审查报告 - 第1轮

> 日期: 2026-07-03
> 范围: PR-1 到 PR-9 的需求文档、正式方案、详细设计、代码实现、单元测试与专项进度 checklist。
> 结论: 主体实现已经覆盖 Starred/知识库语义拆分，但仍有少量代码缺口、测试证据不足与 checklist 未回填。

## 1. 审查输入

- 需求讨论: `docs/2-产品/需求讨论/Starred与知识库语义拆分需求讨论.md`
- 正式方案: `docs/2-产品/需求讨论/正式方案/Starred与知识库正式方案.md`
- 详细设计: `docs/3-设计/详细设计/38-Starred与知识库改造详细设计.md`
- 专项进度: `docs/4-工程进度/Starred与知识库专项/Starred与知识库专项进度.md`
- 代码重点: `RepoDetailScaffold`、`DiscoveryDetailView`、`HomeViewModel`、`SemanticIndexBuilder`、`StarcatMCPFacade`、`RepoAIInsightViewModel`
- 测试重点: `RepoNoteRepositoryTests`、`RepoRepositoryTests`、`HomeViewModelFilterSortTests`、`SemanticIndexingTests`、`SemanticSearchTests`

## 2. 发现的问题

### A1. PR-1 未登录态仍展示详情页知识库 ❤️

进度文档要求“未登录态不展示用户私有知识库，也不允许修改 `libraryState`”。当前 `RepoDetailScaffold.trailingActionsView` 无条件渲染 `LibraryToggleButton`，点击后才在 `handleLibraryToggleTapped()` 内触发登录弹窗。写入已被拦截，但“未登录态不展示”未满足。

修复方向: `RepoDetailScaffold` 仅在 `authSession.state.isAuthenticated && repo.id > 0` 时渲染 ❤️。这也自然满足“离线且未落库的外部 repo 不能直接加入知识库”。

### A2. PR-3 Discovery 详情页 ❤️ checklist 未完成，需要复核 scaffold 条件后回填

`DiscoveryScaffoldShell.trailingActions(for:)` 只控制 share / AI。知识库 ❤️ 由共用 `RepoDetailScaffold` 内部渲染，因此 Discovery 详情只要传入 `repo.id > 0` 且已登录，就会复用同一入口。当前 checklist 仍未勾选，属于实现位置与 checklist 理解不一致。

修复方向: 完成 A1 后用同一渲染条件确认 Discovery 详情已覆盖，再回填 PR-3 checklist。

### A3. PR-5 三种语义候选范围缺少直接单测

`HomeViewModel.fetchSearchCandidates(scope:)`、`SemanticIndexBuilder.fetchRepos(scope:)`、`StarcatMCPFacade.fetchRepos(scope:)` 都已按 `starred / knowledge / all` 分派。现有测试只覆盖 `all` 合并去重，以及 Repository 的知识库查询，缺少“同一候选输入下三种 scope 分派”的直接单测证据。

修复方向: 给 `SemanticIndexScope` 增加小型纯函数 `selectCandidates(...)`，复用到 Home / Builder / MCP，再补单测覆盖 `starred`、`knowledge`、`all`。

### A4. PR-5 “单仓 AI 摘要仍允许未入库 repo 显式触发”应回填 checklist

`RepoAIInsightViewModel.generate(repo:includeTags:)` 没有按知识库状态拦截；AI 浮窗打开后未 star repo 通过 `includeTags == false` 仍可生成摘要，只是不生成标签建议。代码已满足需求，专项进度未勾选。

修复方向: 回填 PR-5 checklist，并在实现说明中标明代码依据。

### A5. JSON 导入/导出已延期，不作为本轮缺口

PR-1 与 §11.8 的 JSON 导入/导出条目仍未勾选，但进度文档已有明确“延期”说明。该项与用户确认一致，本轮只保留规则，不实施。

修复方向: 不改代码；保持延期备注。

### A6. 人工验证 checklist 大量未回填

§11 中仍有多项人工验证未勾选，其中一部分已经有自动化测试或代码证据，例如 ShareCard 导出、PR-9 后台候选范围、单仓 AI 摘要。另一部分确实需要运行 App 手动验证，例如列表角标可视状态、不可访问 repo UI 标记。

修复方向: 自动化或代码证据充分的条目随修复回填；真实手动项保留未勾选，避免伪造人工验收。

## 3. 本轮修复清单

- 修复 A1: 未登录态隐藏详情页 ❤️，并补充代码注释说明私有知识库入口的登录前提。
- 修复 A3: 抽出 `SemanticIndexScope.selectCandidates(...)` 并补充三范围单测。
- 修复 A2/A4/A6: 回填专项进度中已有代码与测试证据支撑的 checklist。

## 4. 后续复查重点

- 复查 PR-2 不可访问 repo 的 UI 标记是否已有稳定字段承载；如果没有，需要单独补设计与实现。
- 复查 README 无缓存且权限不足的 UI 状态是否能区分“无 README”和“不可访问”。
- 修复完成后运行相关最小测试，再按结果决定是否扩大到 build。
