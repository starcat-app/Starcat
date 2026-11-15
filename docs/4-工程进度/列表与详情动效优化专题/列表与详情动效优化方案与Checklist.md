# 列表与详情动效优化方案与 Checklist

> 状态：源码盘点完成，分批实施方案待确认；本文新增的改造与人工验收项均未开始。
> 创建：2026-11-15
> 盘点基线：主仓库 `dev` 的 `dc0e32f6`，并核对至 `4f92a06c`；两者之间仅有每日热点封面悬停与侧栏 Linux.do 图标调整，不改变本次列表盘点结论。后续提交不自动计入本次盘点。
> 对照分支：`codex/daily-recommendation-cards`；对照快照为 `41f04d9a`，推荐中栏行表面的动效参考与盘点时一致。
> 本次授权：整理专题文档及 checklist；后续代码实施仍需 dong4j 确认具体批次。
> 关联决策：[开发前问题清单](../../1-立项/开发前问题清单.md)中的“列表交互与加载默认约定”及“全局列表动效优化专题”。
> 统一标准：[UI-列表与详情切换动效规范](../../5-规范/UI-列表与详情切换动效规范.md)。本文负责范围、差异、实施顺序与验收记录，不另建一套动效规范。

## 1. 目标与范围

将设置页、仓库 Skills 安装窗口已经采用的 Codenotch 风格交互，逐步落实到 Starcat 其余适用的列表与关联详情：常规行有斑马纹和悬停反馈，持续单选有跨行弹簧背景，详情有完整出入场，主体异步加载有贴合布局的动态骨架。

本专题覆盖 RAG 工作台、Agent 工作台、知识库窗口、独立 Skill 管理工作台、主窗口中栏、管理与审核窗口，以及小弹窗和信息列表。以下清单是本次源码盘点的改造候选；实施时须复核对应页面的真实选择语义与最新代码，不按文件名机械套用效果。

### 1.1 明确排除

**主窗口最左侧“星标 / 探索”等分类导航不在本专题范围内。** 此处曾经试做并被 dong4j 驳回，不能借全局统一再次改动 `SidebarView` 的分类切换、选中背景或导航路由。

该排除不影响主窗口中栏 Repo 列表，也不影响 RAG、Agent、独立 Skill 工作台各自的左栏。三者是不同的界面区域，不能把“排除主侧栏”扩大为排除所有左侧列表。

图表、日历、图谱画布、聊天消息、卡片网格、原生 Menu / Picker、徽章、颜色与图标网格、套餐及欢迎引导不批量套用跨行滑块。特殊形态的处理见第 6 节。

### 1.2 两套 Skill 界面分别处理

| 界面 | 入口与现状 | 本专题处理 |
|---|---|---|
| 仓库 Skills 安装窗口 | 仓库详情中的 Skills 入口；`RepoSkillSelectionPane` / `RepoSkillDetailPane`，已有跨行选中、阅读区过渡和骨架实现 | 作为参考基线；补查其辅助 Inspector，不重做已存在的主流程 |
| 独立 Skill 管理工作台 | 独立三栏窗口；`SkillWorkspaceView` / `SkillDetailView`，已合入 `dev` | 单独列出左栏、中栏多选、详情及文件预览的改造项 |

`RAGConversationHistoryWindow.swift` 是会话数据窗口模型，不是独立 UI 窗口，不计入窗口改造清单。

## 2. 处理原则与已有基准

### 2.1 按交互语义决定效果

| 场景 | 本专题处理 | 必须保留 |
|---|---|---|
| 常规信息行、可点击行 | 低对比斑马纹、整行平滑悬停；有异步主体时补骨架 | 原有行高、点击区、颜色和操作 |
| 持续单选列表 → 详情 | 在上述基础上增加共享选中背景与描边的跨行弹簧动画、详情完整过渡 | 键盘选择与稳定的详情身份 |
| 多选列表 | 每项保留勾选态；有独立当前详情项时只为该项设置导航反馈 | 批量勾选、范围选择、键盘焦点与当前详情互相独立 |
| 手风琴、目录、树形列表 | 行反馈、展开收起和对应内容的过渡；按层级构造骨架 | 层级、缩进、展开状态及整行点击 |
| 异步正文 / WebView | 旧内容退场后更新，当前文档 ready 后入场；等待时显示对应骨架 | 任务取消、文档身份、复用阅读器和错误恢复 |
| 下载、安装、生成与流式输出 | 列表反馈按语义补齐；内容初载与真实任务进度分开表达 | 百分比、步骤、取消、重试及已生成内容 |
| 卡片、画布、原生控件 | 按既有形态补适用的悬停、过渡或骨架 | 原有空间语义及系统交互 |

具体参数、Reduce Motion、颜色、分页和状态约束均以[统一规范](../../5-规范/UI-列表与详情切换动效规范.md)为准。仅新增 hover、切换普通底色或只让新详情淡入，不能算作完成“单选列表 → 详情”的完整改造。

### 2.2 已有能力与复用入口

| 参考 | 源码入口 | 可以参考的能力与限制 |
|---|---|---|
| 设置页 | [SettingsView.swift](../../../Starcat/Features/Settings/SettingsView.swift) | 共享选中背景、悬停和原生详情交叉模糊过渡；保留图标颜色与表单保存行为 |
| 仓库 Skills 选择 | [RepoSkillSelectionPane.swift](../../../Starcat/Features/Home/RepoSkillSelectionPane.swift) | 懒加载中的跨行选中背景；当前阅读项与批量勾选独立 |
| 仓库 Skills 阅读 | [RepoSkillDetailPane.swift](../../../Starcat/Features/Home/RepoSkillDetailPane.swift) | 退场快照、动画完成回调、稳定 WebView 和当前文档 ready 校验 |
| 仓库 Skills 骨架 | [RepoSkillSkeletonView.swift](../../../Starcat/Features/Home/RepoSkillSkeletonView.swift) | 列表、正文、文件和目录骨架；主题与扫光时钟复用 |
| 通用 Repo 行 | [RepoRowSurface.swift](../../../Starcat/Shared/Components/RepoRowSurface.swift)、[UnifiedRepoRow.swift](../../../Starcat/Shared/Components/UnifiedRepoRow.swift) | `dev` 已有选中、hover 和语义颜色基础；尚未具备推荐分支新增的共享 `selectionNamespace` 接口 |
| 推荐中栏行 | 对照分支中的 `RepoRowSurface.swift`、`UnifiedRepoRow.swift`、`RecommendationHistoryListView.swift` | 已传递共享 `selectionNamespace`，背景与描边跨行弹簧移动；推荐详情仍复用 `DiscoveryDetailView`，不能据此宣称详情整套动效已完成 |

RAG 会话、每日热点阅读器、Issues、搜索等页面也已有局部骨架或过渡。下文按差异补齐，不把已有能力写成全部缺失。

上述“已有”只表示源码中存在对应路径。本次没有操作 GUI，没有完成新的视觉验收；历史实现、自动化通过与实际动效验收分别保留状态。

### 2.3 共享能力先核对

- [ ] **基础-01**：复核推荐分支与当前 `dev` 的 `RepoRowSurface` / `UnifiedRepoRow` 差异，确定后续共享接口的来源；只对齐所需能力，不为本专题擅自合并整条推荐分支。
- [ ] **基础-02**：逐个核对通用 Repo 行调用方的选择语义与 namespace 归属；每个独立列表持有稳定共享空间，避免把一个滑块跨多个窗口或列表复用。
- [ ] **基础-03**：盘点可复用的骨架表面、主题色、扫光时钟与详情就绪信号；页面布局不同的骨架按真实内容组合。
- [ ] **基础-04**：明确组件复用的最小边界；若需要新增通用动效组件，先单独说明调用场景与成本，不能恢复此前已废弃的整套共享导航重构。

## 3. 第一批：重点工作台 Checklist

本批优先处理 dong4j 点名的 RAG、Agent 和知识库窗口，并将独立 Skill 工作台作为相近场景单独推进。每个编号表示该子场景完成适用效果的改造与验证准备；实际视觉验收另外登记。

### 3.1 RAG 工作台

- [ ] **A01 · 会话列表 → 对话中栏**：覆盖置顶、分组与未分组会话。行已有条纹、hover 和普通选中，补跨行背景与描边；中栏已有骨架交接，核对旧会话退场、新会话就绪入场。入口：[ConversationRail](../../../Starcat/Features/RAG/UI/RAGWorkspaceConversationRail.swift)、[ConversationRow](../../../Starcat/Features/RAG/UI/RAGWorkspaceConversationRow.swift)、[AnswerSurface](../../../Starcat/Features/RAG/UI/RAGWorkspaceAnswerSurface.swift)。

- [ ] **A02 · 上下文仓库选择**：覆盖弹层中的搜索、筛选与仓库多选；补齐行反馈及首载骨架，保持勾选与键盘聚焦独立。入口：[AnswerSurface](../../../Starcat/Features/RAG/UI/RAGWorkspaceAnswerSurface.swift)、[RAGContextPickerFilterControls](../../../Starcat/Features/RAG/UI/RAGContextPickerFilterControls.swift)。

- [ ] **A03 · 入库候选窗口**：已有条纹，补查整行悬停、选择、主体加载及结果交接；入库操作进度继续使用真实状态。入口：[RAGAddToLibrarySheet](../../../Starcat/Features/RAG/UI/RAGAddToLibrarySheet.swift)。

- [ ] **A04 · Inspector 引用、远程来源与仓库排行**：引用是行内手风琴展开，不是整栏单选详情；按各自语义补反馈和内容交接。入口：[RAGWorkspaceInspector](../../../Starcat/Features/RAG/UI/RAGWorkspaceInspector.swift)。

- [ ] **A05 · 检索候选、重排与命中列表**：核对已有条纹及 hover，补缺失的首载占位、展开与详情切换；保留真实评分、排序和定位。入口：[RAGWorkspaceInspector](../../../Starcat/Features/RAG/UI/RAGWorkspaceInspector.swift)。

- [ ] **A06 · 索引覆盖、Debug trace / 事件、当前仓库分片**：部分 payload 已有骨架；补查行反馈、展开与当前请求交接，避免再次建立逐行动画计时器。入口：[RAGWorkspaceInspector](../../../Starcat/Features/RAG/UI/RAGWorkspaceInspector.swift)。

- [ ] **A07 · 引用分片与 XML 预览弹层**：已有骨架交接基础，核对引用、RepoContext XML、RepositoryInsights XML 三处的就绪信号、失败与切换效果。入口：[RAGCitationChunkPopover](../../../Starcat/Features/RAG/UI/RAGCitationChunkPopover.swift)、[RAGRepoContextXMLPopover](../../../Starcat/Features/RAG/UI/RAGRepoContextXMLPopover.swift)、[RAGRepositoryInsightsXMLPopover](../../../Starcat/Features/RAG/UI/RAGRepositoryInsightsXMLPopover.swift)。

### 3.2 Agent 工作台

- [ ] **A08 · Agent 目录、历史任务 → 当前工作区**：当前以普通选中背景为主，补连续选中反馈及关联内容出入场；切换不能中断真实运行任务。入口：[AgentWorkspaceView](../../../Starcat/Features/Agents/Core/AgentWorkspaceView.swift)。

- [ ] **A09 · 上下文仓库多选**：补行条纹、hover、首载骨架，保留批量勾选、键盘与搜索语义。入口：[AgentWorkspaceRunSurface](../../../Starcat/Features/Agents/Core/AgentWorkspaceRunSurface.swift)。

- [ ] **A10 · 产物列表 → 产物详情**：补持续选中背景和详情交接；按正文、文件等实际产物类型提供等待骨架。入口：[AgentRunInspectorView](../../../Starcat/Features/Agents/Core/AgentRunInspectorView.swift)。

- [ ] **A11 · 过程事件、消息内事件 → Inspector**：补事件行反馈和 Inspector 当前项切换；保留流式追加、跟随滚动和过程展开行为。入口：[AgentHarnessProcessView](../../../Starcat/Features/Agents/Core/AgentHarnessProcessView.swift)、[AgentMessageTimelineView](../../../Starcat/Features/Agents/Core/AgentMessageTimelineView.swift)。

- [ ] **A12 · 知识引用与审计证据**：补证据列表反馈及对应内容交接，保留引用来源与定位。入口：[AgentKnowledgeAuditView](../../../Starcat/Features/Agents/Core/AgentKnowledgeAuditView.swift)。

- [ ] **A13 · Inspector 上下文仓库、附件与链接行**：区分信息行、外链与持续选择，不给一次性打开操作虚构选中滑块；补适用的条纹、hover 和内容加载。入口：[AgentRunInspectorView](../../../Starcat/Features/Agents/Core/AgentRunInspectorView.swift)。

### 3.3 知识库窗口

以下四项均位于 [KnowledgeRAGWorkspaceWindowController.swift](../../../Starcat/Features/RAG/UI/KnowledgeRAGWorkspaceWindowController.swift)。

- [ ] **A14 · 仓库列表 → 索引详情**：列表复用 `UnifiedRepoRow`，对齐共享选中能力；详情现有 loading overlay 应区分内容首载与已有内容刷新，补对应骨架及完整交接。

- [ ] **A15 · 检索测试 → 命中结果**：输入与真实检索进度保持原语义；结果首载使用命中行骨架，命中定位或关联详情增加适用过渡。

- [ ] **A16 · 分片列表 → 编辑弹层**：分片行已有条纹和 hover；补查加载、展开及打开编辑器的过渡。`KnowledgeRAGChunkEditor` 是编辑弹层，不改造成右侧单选详情，不因动画丢失未保存内容。

- [ ] **A17 · RepoContext / RepositoryInsights 元信息与 XML 预览**：区分只读字段、列表行和阅读区，补适用的悬停、骨架与就绪交接，保留真实索引状态。

### 3.4 独立 Skill 管理工作台

- [ ] **A18 · 左栏分类、Agent 与来源 → 中栏列表**：核对原生 `List(selection:)` 的选择与键盘行为后补适用的跨行背景；中栏筛选结果有平滑交接。入口：[SkillWorkspaceView](../../../Starcat/Features/Skills/SkillWorkspaceView.swift)。

- [ ] **A19 · 中栏 Skill 多选 → 当前详情**：当前采用原生多选列表，主体 loading 为旋转指示器；补布局匹配的骨架、条纹与 hover，明确当前详情项与多选集合的关系，不能用一个滑块覆盖所有已选项。入口：[SkillWorkspaceView](../../../Starcat/Features/Skills/SkillWorkspaceView.swift)。

- [ ] **A20 · 概览 / 文件 / 分配 / 版本内容切换**：补完整详情出入场，保留独立三栏宿主、栏宽、当前 Skill 及表单状态。入口：[SkillDetailView](../../../Starcat/Features/Skills/SkillDetailView.swift)。

- [ ] **A21 · 文件列表 → 内容预览**：列表和预览首载均补骨架及交接；当前为原生 MarkdownUI 路径，不照搬安装窗口的 WebView 生命周期。入口：[SkillContentView](../../../Starcat/Features/Skills/SkillContentView.swift)。

## 4. 第二批：主窗口中栏、搜索与洞察 Checklist

本批只处理中栏对象列表和关联详情；主窗口最左侧分类导航继续排除。Repo 卡片保留现有表面，不机械叠加普通行斑马纹。

- [ ] **B01 · 星标、标签 / 语言筛选、主窗口知识库及项目列表**：对齐通用 Repo 行选中背景与详情切换；检查不同模式的多选、拖拽、分页和缓存回切。入口：[RepoListView](../../../Starcat/Features/Home/RepoListView.swift)。

- [ ] **B02 · 探索仓库列表**：接入适用的共享选中反馈，补查对应详情和首载骨架；保留既有来源、筛选及分页。入口：[ExploreView](../../../Starcat/Features/Explore/ExploreView.swift)。

- [ ] **B03 · Awesome 项目列表**：补列表选择与关联详情交接，保留来源及分类语义。入口：[AwesomeView](../../../Starcat/Features/Explore/AwesomeView.swift)。

- [ ] **B04 · Linux.do 项目列表**：补选择反馈与详情交接，保留原帖入口和来源信息。入口：[LinuxDoView](../../../Starcat/Features/Explore/LinuxDoView.swift)。

- [ ] **B05 · 趋势列表**：对齐通用行能力，保留周期、排序、缓存、增量加载与语言颜色。入口：[TrendingView](../../../Starcat/Features/Trending/TrendingView.swift)。

- [ ] **B06 · 动态列表**：分别核对仓库型行与特殊活动行，统一适用反馈和详情过渡；不破坏现有首屏入场与刷新策略。入口：[ActivityView](../../../Starcat/Features/Activity/ActivityView.swift)。

- [ ] **B07 · 周刊项目列表**：补仓库选择、详情及加载交接，保留来源筛选和分页。入口：[WeeklyContentView](../../../Starcat/Features/Activity/WeeklyContentView.swift)。

- [ ] **B08 · 取消 Star 记录**：补行反馈及当前详情切换，保留已有多选和恢复 / 操作语义。入口：[UndoStarContentView](../../../Starcat/Features/Activity/UndoStarContentView.swift)。

- [ ] **B09 · Search Center 结果 → 详情**：已有列表骨架和部分切换，按仓库、网页等结果类型补齐出入场；保留键盘、来源渐进结果和当前请求隔离。入口：[SearchCenterView](../../../Starcat/Features/Search/SearchCenterView.swift)。

- [ ] **B10 · GitHub 通知 → 通知详情**：补条纹、hover、持续单选背景及详情交接；首载主体替换单独旋转占位，刷新保留通知。入口：[GitHubNotificationInboxView](../../../Starcat/Features/Activity/GitHubNotificationInboxView.swift)、[GitHubNotificationDetailView](../../../Starcat/Features/Activity/GitHubNotificationDetailView.swift)。

- [ ] **B11 · 洞察主题导航 → 内容**：补适用的选中背景及内容过渡，不改主题路由。入口：[InsightsNavigationViews](../../../Starcat/Features/Insights/InsightsNavigationViews.swift)。

- [ ] **B12 · 我的洞察：优先仓库、排名与行动项**：区分导航与一次性操作行，补行反馈、关联详情与初载交接；保留统计和排序。入口：[MyInsightsView](../../../Starcat/Features/Insights/MyInsightsView.swift)。

- [ ] **B13 · 共用 Repo 详情承载**：核对 Manage 与 Discovery 等路径的原生内容、README 骨架和 ready 交接。不能为重播动画给整个详情加 `.id(repoID)`，破坏稳定 Scaffold / `WKWebView`、滚动及页面状态。入口：[RepoDetailView](../../../Starcat/Features/Home/RepoDetailView.swift)。

## 5. 第三批：管理与审核窗口 Checklist

- [ ] **C01 · 仓库文件树 → 文件预览**：左右初载分别提供树形 / 正文骨架，补当前文件选择与预览交接；文件勾选与当前预览保持独立。入口：[RepoFileBrowserSheet](../../../Starcat/Features/Home/RepoFileBrowserSheet.swift)。

- [ ] **C02 · Issues 列表 → Issue 详情**：已有列表骨架和约 220ms 详情透明度切换；补核对跨行选择与完整出入场，复用已有骨架。入口：[RepoIssuesWorkspaceView](../../../Starcat/Features/RepoIssues/RepoIssuesWorkspaceView.swift)。

- [ ] **C03 · 标签管理 → 编辑及合并候选**：保留标签多选，补行反馈、当前编辑项交接及适用骨架；不让过渡丢失编辑状态。入口：[TagManagementView](../../../Starcat/Features/Tags/TagManagementView.swift)。

- [ ] **C04 · 标签体系准备 / 扩词候选 → 证据与示例**：候选多选与 `focusedCandidate` 独立处理，补当前证据切换和加载骨架。入口：[TagTaxonomyBootstrapView](../../../Starcat/Features/AI/TagTaxonomyBootstrapView.swift)。

- [ ] **C05 · 批量 AI 队列与标签审核**：`BatchAITagReviewRow` 已有条纹和 hover，补查展开、审核及等待内容；生成、应用和取消继续展示真实进度。入口：[BatchAIQueuePanel](../../../Starcat/Features/AI/BatchAIQueuePanel.swift)。

- [ ] **C06 · GitHub Lists AI 分组预检规则**：补规则行反馈和展开 / 内容交接，保留预检选择及确认。入口：[GitHubStarListAIGroupingPreflightView](../../../Starcat/Features/Home/GitHubStarListAIGroupingPreflightView.swift)。

- [ ] **C07 · GitHub Lists AI 分组结果与多分组选择**：补审核结果行和多选行反馈，关联内容按真实选择过渡；保留全部勾选状态。入口：[GitHubStarListAIGroupingResultList](../../../Starcat/Features/Home/GitHubStarListAIGroupingResultList.swift)、[GitHubStarListAIMultiGroupPicker](../../../Starcat/Features/Home/GitHubStarListAIMultiGroupPicker.swift)。

- [ ] **C08 · 仓库 AI 历史会话 → 对话**：补历史行反馈及会话切换交接，保留已有消息、草稿和流式任务。入口：[RepoAIWindowContentView](../../../Starcat/Features/AI/RepoAIWindowContentView.swift)。

- [ ] **C09 · 仓库 AI 建议标签与引用来源**：按候选选择、引用展开及外链语义补条纹、hover 和等待内容，不能把流式输出全替换为骨架。入口：[RepoAIWindowContentView](../../../Starcat/Features/AI/RepoAIWindowContentView.swift)。

- [ ] **C10 · Skill 批量更新条目 → 差异 / 分配详情**：补持续单选背景、详情出入场和对应骨架，保留逐项更新决定。入口：[SkillBatchUpdateSheet](../../../Starcat/Features/Skills/SkillBatchUpdateSheet.swift)。

- [ ] **C11 · Skill 批量分配审核**：补多选行、目标与结果反馈，真实分配进度保持独立。入口：[SkillBatchAssignmentSheet](../../../Starcat/Features/Skills/SkillBatchAssignmentSheet.swift)。

- [ ] **C12 · Skill 更新审核**：补版本 / 文件差异列表反馈和内容交接，保留确认与冲突决定。入口：[SkillUpdateReviewSheet](../../../Starcat/Features/Skills/SkillUpdateReviewSheet.swift)。

- [ ] **C13 · Skill 移除审核**：补待移除及影响列表的条纹、hover 和适用加载；移除确认不因整行手势而误触。入口：[SkillRemovalReviewSheet](../../../Starcat/Features/Skills/SkillRemovalReviewSheet.swift)。

- [ ] **C14 · Skill 分配列表**：补目标、分配状态及相关操作行反馈；暂停、恢复、移除继续沿用原语义。入口：[SkillAssignmentsView](../../../Starcat/Features/Skills/SkillAssignmentsView.swift)。

- [ ] **C15 · 仓库 Skills 安装 Inspector**：逐项检查安装目标、队列与冲突行的反馈及内容交接；保留安装真实进度、取消与重试，不重做已完成的左栏及阅读区。入口：[RepoSkillInspector](../../../Starcat/Features/Home/RepoSkillInspector.swift)。

- [ ] **C16 · AI 模型管理列表**：补可见行反馈、选择与加载；`AIModelManagementSheet` 复用同一列表，保持固定 AppKit 高度宿主与搜索行为。入口：[AIModelListView](../../../Starcat/Features/Settings/AIModelListView.swift)。

- [ ] **C17 · 本地 AI 模型目录与下载项**：补条纹、hover、目录加载骨架与局部内容过渡；下载百分比、校验和取消保留。入口：[LocalAIModelsSection](../../../Starcat/Features/Settings/LocalAIModelsSection.swift)。

- [ ] **C18 · 系统翻译语言包列表**：补行反馈、初次状态查询与结果交接；保留 Apple 管理的可用性、下载及授权语义。入口：[SystemTranslationLanguageManagerSheet](../../../Starcat/Features/Settings/SystemTranslationLanguageManagerSheet.swift)。

- [ ] **C19 · CC Switch 导入预览与结果**：覆盖可导入、跳过、成功和失败项，补行反馈与状态交接，保留原有勾选及导入决定。入口：[CCSwitchImportPreviewSheet](../../../Starcat/Features/Settings/CCSwitchImport/CCSwitchImportPreviewSheet.swift)。

- [ ] **C20 · MCP / Pro 设备列表**：分别补设备行反馈和首次加载交接，保留授权、解绑及刷新语义。入口：[MCPSettingsView](../../../Starcat/Features/MCP/MCPSettingsView.swift)、[ProSettingsView](../../../Starcat/Features/Settings/ProSettingsView.swift)。

- [ ] **C21 · AI 用量维度与明细表**：补适用的行反馈、主体骨架和数据交接；原生 `Table` 保留排序、列宽与键盘行为，不强行替换成自绘列表。入口：[AIUsageDashboardView](../../../Starcat/Features/AI/Usage/AIUsageDashboardView.swift)。

## 6. 第四批：小窗口、弹层与特殊形态 Checklist

### 6.1 小弹窗与信息列表

这些场景可能只有选择、外链或信息展示，没有持久详情。只应用实际适用的反馈，不为一次性点击增加虚假的持续选中。

- [ ] **D01 · 语言搜索与兴趣语言选择**：覆盖设置、主列表筛选和 RAG 上下文筛选三处，保留搜索、多选及当前值。入口：[SettingsView](../../../Starcat/Features/Settings/SettingsView.swift)、[RepoListView](../../../Starcat/Features/Home/RepoListView.swift)、[RAGContextPickerFilterControls](../../../Starcat/Features/RAG/UI/RAGContextPickerFilterControls.swift)。

- [ ] **D02 · 仓库标签选择弹层**：补搜索结果行、勾选与 hover，保留多选和新建语义。入口：[RepoTagsSection](../../../Starcat/Features/Tags/RepoTagsSection.swift)。

- [ ] **D03 · 智能集合多选字段**：补选项行反馈，保持多选值与键盘焦点。入口：[SmartCollectionMultiSelectField](../../../Starcat/Features/Collections/SmartCollectionMultiSelectField.swift)。

- [ ] **D04 · 分支选择弹层**：覆盖 CodeFlow 与文件浏览两处；按单选 / 确认后关闭语义补反馈，不能影响分支实际加载。入口：[CodeFlowPanel](../../../Starcat/Features/CodeGraph/CodeFlowPanel.swift)、[RepoFileBrowserSheet](../../../Starcat/Features/Home/RepoFileBrowserSheet.swift)。

- [ ] **D05 · 后台任务列表**：补任务行反馈与展开交接，保留真实状态、查看与取消能力，不新增任务进度条。入口：[AppBackgroundTaskList](../../../Starcat/Features/Home/AppBackgroundTaskList.swift)。

- [ ] **D06 · 本地 AI 状态列表**：补模型 / Runtime 信息行反馈和内容交接，保留真实资源状态。入口：[LocalAIStatusSection](../../../Starcat/Features/Home/LocalAIStatusSection.swift)。

- [ ] **D07 · 外部 Star 收件箱**：补收件项反馈及主体等待状态，保留确认和实际 Star 操作。入口：[ExternalStarInboxCapsule](../../../Starcat/Shared/Components/ExternalStarInboxCapsule.swift)。

- [ ] **D08 · 贡献者弹窗**：补贡献者行反馈与初载骨架，外链点击不设持久单选滑块。入口：[RepoContributorsStatItem](../../../Starcat/Features/Home/RepoContributorsStatItem.swift)。

- [ ] **D09 · 仓库健康度明细**：补指标 / 发现项的行反馈、展开与首载交接，保留评分事实和说明层级。入口：[RepoHealthSheet](../../../Starcat/Features/Home/RepoHealthSheet.swift)。

- [ ] **D10 · OpenSSF 检查明细**：补检查行反馈和加载交接，保留真实分数、状态及证据链接。入口：[OpenSSFScoreSheet](../../../Starcat/Features/Home/OpenSSFScoreSheet.swift)。

- [ ] **D11 · 发布历史与下载资源**：补版本 / 资源行反馈、展开及正文加载交接；真实下载进度继续保留。入口：[ReleaseTimelineView](../../../Starcat/Features/Releases/ReleaseTimelineView.swift)。

- [ ] **D12 · 周刊来源事件**：补来源行反馈与展开交接，保留原始来源链接。入口：[WeeklySourceEventsSection](../../../Starcat/Features/Activity/WeeklySourceEventsSection.swift)。

- [ ] **D13 · 动态详情发布资源**：覆盖独立发布内容和通用动态详情中的资源列表，避免只改其中一处。入口：[ActivityReleaseDetailContent](../../../Starcat/Features/Activity/ActivityReleaseDetailContent.swift)、[ActivityDetailView](../../../Starcat/Features/Activity/ActivityDetailView.swift)。

- [ ] **D14 · 仓库洞察内部信息列表**：分别核对贡献者、发布资源、安全公告和时间线的反馈、展开及内容加载。入口：[RepositoryInsightsView](../../../Starcat/Features/Insights/RepositoryInsightsView.swift)。

- [ ] **D15 · 关于页内容与依赖列表**：保留系统 segmented 控件，补内容页过渡和依赖行反馈；更新说明按阅读 / 展开内容处理。入口：[AboutView](../../../Starcat/Features/About/AboutView.swift)。

- [ ] **D16 · 推荐项目弹窗**：补项目行反馈、适用选择与等待交接，不重复承诺推荐分支详情已改造。入口：[RepoRecommendationPopover](../../../Starcat/Features/Recommendations/RepoRecommendationPopover.swift)。

- [ ] **D17 · 每日热点关联项目行**：补行反馈及进入关联项目详情的交接，保持既有项目面板边界。入口：[DailyRadarRelatedProjectRow](../../../Starcat/Features/DailyRadar/DailyRadarRelatedProjectRow.swift)。

- [ ] **D18 · 批量 Star 确认预览**：补候选行反馈及初载占位，保留原有勾选、数量与确认行为。入口：[BatchStarConfirmSheet](../../../Starcat/Features/Home/BatchStarConfirmSheet.swift)。

- [ ] **D19 · 取消 Star 数据保留选择**：补数据项行反馈，保留数据处理决定和确认边界。入口：[RepositoryUnstarDataChoiceSheet](../../../Starcat/Shared/Components/RepositoryUnstarDataChoiceSheet.swift)。

- [ ] **D20 · Profile 组织入口的适用性记录**：源码为横排头像按钮与原生溢出 Menu，已有局部 hover 和头像占位，并非普通行列表。按不适用项登记，保留现有形态，不增加条纹、单选滑块或主体骨架，不扩大到主侧栏资料区。入口：[ProfileOrganizationsView](../../../Starcat/Features/Profile/ProfileOrganizationsView.swift)。

### 6.2 保留特殊形态的场景

- [ ] **E01 · 每日热点预览、历史与阅读器**：预览保留卡片网格；历史行已有条纹 / hover，阅读器已有 ready 后骨架交接，重点查漏和回归，不重新实现相同流程。入口：[DailyRadarPreviewWorkspace](../../../Starcat/Features/DailyRadar/DailyRadarPreviewWorkspace.swift)、[DailyRadarPreviewReader](../../../Starcat/Features/DailyRadar/DailyRadarPreviewReader.swift)。

- [ ] **E02 · 智能集合概览网格**：保留集合卡片形态，只核对悬停、打开内容与适用的加载交接，不套普通行斑马纹。入口：[SmartCollectionsOverviewView](../../../Starcat/Features/Collections/SmartCollectionsOverviewView.swift)。

- [ ] **E03 · 智能集合详情瀑布流**：已有骨架，保留瀑布流与卡片布局，检查骨架到内容交接及点击反馈。入口：[SmartCollectionDetailPanel](../../../Starcat/Features/Collections/SmartCollectionDetailPanel.swift)。

- [ ] **E04 · Awesome 来源管理网格**：保留来源卡片，补适用的 hover、选择反馈和等待交接，不替换成行列表。入口：[AwesomeSourceManagerSheet](../../../Starcat/Features/Explore/AwesomeSourceManagerSheet.swift)。

- [ ] **E05 · 关系图谱搜索结果 → 画布定位**：补搜索行反馈及适用的初载骨架，保留画布定位、镜头与节点选择语义，不引入普通右侧详情切换。入口：[FollowGraphOverlayView](../../../Starcat/Features/FollowGraph/FollowGraphOverlayView.swift)。

- [ ] **E06 · RAG 对话大纲 rail**：保留现有小横线导航形态，按定位语义核对 hover 和当前项反馈，不扩成普通会话列表。入口：[RAGConversationOutlineRail](../../../Starcat/Features/RAG/UI/RAGConversationOutlineRail.swift)。

- [ ] **E07 · 不适用场景复核**：记录纯说明、提示词占位符、权限与引导 scope、徽章及原生控件的适用判断；无列表选择或主体异步加载时，标明不适用，不为凑统一效果新增交互。

## 7. 实施顺序与提交边界

以下为建议顺序，具体批次以 dong4j 后续授权为准。批次是验收分组，不要求把所有页面堆在一个提交里。

| 阶段 | 范围 | 开始前必须明确 | 交付边界 |
|---|---|---|---|
| 共享基础核对 | 基础-01～04 | 推荐分支所需能力如何对齐、现有骨架如何复用 | 仅需要的行表面接口与复用决定，不合并无关推荐功能 |
| 第一批 | A01～A21 | 各工作台的单选 / 多选、详情身份及真实就绪信号 | RAG、Agent、知识库、独立 Skill 按功能分提交、逐页验收 |
| 第二批 | B01～B13 | Repo 共享行与详情承载的依赖、历史性能约束 | 中栏及对应详情；主侧栏分类逻辑排除 |
| 第三批 | C01～C21 | 审核、编辑、多选和真实任务进度的边界 | 管理 / 审核窗口按功能提交，不能把破坏性确认混入整行手势 |
| 第四批 | D01～D20、E01～E07 | 无持久选择与特殊形态的适用性 | 小弹层逐类补齐；不适用项登记理由 |

- [ ] **执行-01**：实施每批前核对最新 `dev`、`BRANCH.md` 与真实 worktree / refs；按 [Git 分支与 Worktree 规范](../../5-规范/Git-分支与Worktree规范.md)创建独立工作区并登记，保留主仓库及其他任务的修改。
- [ ] **执行-02**：新 worktree 复制必要的被忽略本地配置后再测试；不输出或提交配置内容。
- [ ] **执行-03**：每批先选一组完整的“列表 → 详情 → 加载”作为可审查样例，验证节奏后继续同类页面；不以只改 hover 的半成品扩散到所有页面。
- [ ] **执行-04**：共享能力与各功能改造按实际主题提交，避免跨功能大提交；记录每个清单编号对应的 commit。
- [ ] **执行-05**：核对既有 [Repo 列表性能专项](../Repo列表性能优化专项/Repo列表切换性能优化Checklist.md)和 [Skill 管理工作台清单](../../2-产品/需求讨论/Skill管理工作台/12-开发Checklist与实施记录.md)，不因动画回退缓存、分页、首屏或分栏约束。
- [ ] **执行-06**：不改变业务请求、数据模型、下载 / 安装、保存及授权流程；确需跨越 UI 与业务边界时先说明具体改动并纳入该批方案。
- [ ] **执行-07**：按根 `AGENTS.md` 选择相关测试和构建路径；满足简单 UI 改动豁免时不额外构建，涉及状态 / 并发、工程配置或增删 Swift 文件时按完整要求验证。
- [ ] **执行-08**：自动化结果与人工验收分开记录；GUI 操作继续遵守单独授权要求，未实际查看的效果不能写通过。

## 8. 每页验收 Checklist

实施每个页面时逐项检查适用项，不适用的项目在验收记录中写明原因。源码出现 `matchedGeometryEffect`、测试通过或成功启动 App，均不能替代实际看到动效。

### 8.1 列表交互

- [ ] **验收-01**：常规行的斑马纹对比克制，筛选 / 排序后正确，分页追加连续，滚动复用不跳色；卡片与特殊形态维持自己的表面。
- [ ] **验收-02**：鼠标移入 / 移出整行平滑提亮和恢复；选中态优先于 hover，hover 优先于条纹。
- [ ] **验收-03**：可见相邻行与跨多行切换时，背景和描边连续弹簧滑动；文字、图标、复选框、行高和点击区稳定。
- [ ] **验收-04**：搜索、筛选、删除或懒加载导致目标不可见时，当前选中正确落位；不构造不存在的跨行轨迹。
- [ ] **验收-05**：多选勾选、范围选择、键盘聚焦与当前详情项各自正确；新增整行点击不吞掉复选框、按钮、拖拽或上下文菜单。
- [ ] **验收-06**：快速 A → B → C、重复点击当前项、滚动后切换正确，无过期结果回填、详情闪回或无故重播。

### 8.2 详情与内容加载

- [ ] **验收-07**：原生详情旧页确实退场、新页完整入场，分栏尺寸稳定，模糊不越界，不出现只给新页淡入的替代实现。
- [ ] **验收-08**：异步 / WebView 按“旧内容退场 → 更新当前内容 → 当前文档 ready → 入场”交接，标题、附件和目录不提前串到下一项。
- [ ] **验收-09**：初次列表、详情和文件加载使用对应结构的骨架与轻量动画；少量首屏占位，不为每行启动高频时钟。
- [ ] **验收-10**：缓存命中直接进行正常内容过渡，不强插骨架或人为延时；已有内容刷新时保留当前结果。
- [ ] **验收-11**：数据已返回但正文尚未渲染完成时，仍按真实就绪状态交接；不把 HTML / Markdown 准备完成等同于当前文档可显示。
- [ ] **验收-12**：真实空结果、失败、取消及重试均正确结束骨架，不出现永久透明、永久占位或陈旧详情仍可交互。
- [ ] **验收-13**：骨架和隐藏旧内容不可点击，不作为当前真实内容被辅助功能朗读；键盘导航与按钮语义保留。
- [ ] **验收-14**：下载、安装、生成、流式输出与分页追加继续展示真实过程；骨架仅用于尚无可显示主体的加载阶段。

### 8.3 外观、状态与性能

- [ ] **验收-15**：明暗主题、语言色、品牌色和彩色图标正确，选中与 hover 不抹掉原有颜色。
- [ ] **验收-16**：Reduce Motion 下关闭跨行位移、局部微移、模糊与扫光，保留静态高亮、静态骨架和短时淡化。
- [ ] **验收-17**：长文案、窄窗和“始终显示滚动条”下文字与控件不被遮挡；三栏缩放、显隐和栏宽恢复不回退。
- [ ] **验收-18**：表单草稿、文件编辑、展开项、搜索、筛选、排序、分页及原有滚动策略保持正确。
- [ ] **验收-19**：`WKWebView` / 阅读器和长列表宿主不因动画反复重建；无全量创建长列表、整窗宽泛动画或等待期间的额外主线程重活。
- [ ] **验收-20**：大集合滚动、会话切换和详情切换无新增明显卡顿；性能结论有对应环境与观测，不以拉长动画掩盖等待。
- [ ] **验收-21**：主窗口最左侧分类导航没有被本专题改变；设置页与仓库 Skills 既有颜色、动效和操作没有回退。

## 9. 记录与收口

清单勾选表示对应工作的实际完成，不回写为此前已验收。每个页面至少记录以下信息；一次验收可覆盖同一功能下多个编号，但必须列明范围。

| 清单编号 / 页面 | 实现 commit | 自动化验证 | 构建 / 启动 | 人工视觉验收 | 未完成项 / 不适用理由 |
|---|---|---|---|---|---|
| 待实施后填写 | — | 未执行 | 未执行 | 待验收 | 本次仅完成源码盘点与文档落档 |

- [ ] **收口-01**：A～E 中每项有实现与验收记录，或有经确认的不适用 / 暂缓说明；存在缺口时保持专题开放。
- [ ] **收口-02**：共享组件调用方、设置页、仓库 Skills 安装窗口和主侧栏排除范围完成必要回归。
- [ ] **收口-03**：各批提交、自动化验证、人工验收及剩余问题可追溯，不能用一个“全部完成”覆盖未验收页面。
- [ ] **收口-04**：专项关闭前拟好对应主进度条目与 `> 实现：`，取得 dong4j 对 `docs/功能实现总览.md` 的单独授权后再同步；本次文档不改写该总览。
- [ ] **收口-05**：合并、worktree 清理、推送、Changelog 与发布分别按后续授权及对应规范处理，不因文档落档自动执行。

后续新增或修改列表仍由根 `AGENTS.md` 自动引导执行[统一动效规范](../../5-规范/UI-列表与详情切换动效规范.md)；本专题是本次历史界面的补齐清单，不改变默认规范的适用方式。
