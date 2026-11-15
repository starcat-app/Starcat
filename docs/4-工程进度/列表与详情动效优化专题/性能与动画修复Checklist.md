# 列表与详情动效性能修复 Checklist

> 状态：七项代码修复、自动化验证及本地 dev 集成已完成，功能 worktree 和分支已清理；实机流畅度待验收，专题保持开放。
> 授权：2026-11-15，dong4j 要求登记任务、逐项完成、每个修复单独提交。
> 原开发工作区：`Starcat-list-detail-motion` / `codex/list-detail-motion`，原始基线 `b91e22c1`；后续在主工作区 `Starcat` / `dev` 验收。
> 关联：[实施 Checklist](实施Checklist.md)、[优化方案](列表与详情动效优化方案与Checklist.md)、[动效规范](../../5-规范/UI-动效规范.md)。

## 范围与提交顺序

原始专题实现已保存为可比较的基线 `86629936`，再按下表逐项核对和修复，每项修复与相应记录一起提交。此前独立的洞察图标修改不混入性能修复。性能修复阶段只在该 worktree 工作，不合并 dev、不推送、不修改主进度总览或 Changelog；2026-11-16 dong4j 追加授权合入本地 dev 并清理，结果见下方集成记录。

源码可证明多余重建、重复扫描或状态遗漏，但不能证明已经发生彩虹圈；没有线程采样或界面测量时不作该结论。主窗口最左侧分类导航与用户暂缓的全局筛选图标问题均不在本次修复范围。

## 修复任务

- [x] P01 · 隔离行背景动画：将 `ListRowSurface` / `RepoRowSurface` 的 hover、spring 限定在背景、描边和指示条；移除包裹正文的动画及 hover 的全子树交易，保留共享选中与 Reduce Motion。
- [x] P02 · 保留大型展示宿主：Skill 原生多选 List、Agent / RAG / Repo AI 时间线、知识库 / 通知 ScrollView 及含读取任务的 Repo 标题改为稳定身份的轻量淡化；保留原有滚动与加载交接。
- [x] P03 · 修复 README 交接终态：任务身份区分等待、当前文档与终态；核对缓存回切与 ready / failure 回调归属，空结果、登录提示及错误能够触发骨架收口。
- [x] P04 · 修复 Skill 文件预览中断：快速 A → B → A 时先恢复保留的当前文件；刷新失败保留正文和错误反馈，取消 / 过期结果仍由原请求身份守门。
- [x] P05 · 消除新增行索引重复扫描：Skill 分类 / 来源 / Agent 名称、Agent 历史 / 产物、洞察及标签候选共七处行渲染改为传递展示索引；保持稳定业务 ID，不引入派生状态缓存。
- [x] P06 · 核对骨架与其他交接：保留每组共享的骨架时钟和 Reduce Motion；Skill overview / files 页签移除额外的整容器身份切换与全区模糊，其余已有交接保持原职责。
- [x] P07 · 隔离探索详情的 Star 请求回写：请求仍作用于点击时的仓库，完成后只对当前展示快照应用 Registry；不使用旧 item 覆盖当前选择，也不重新加载旧 README。

每项记录填写：触发条件、源码证据、修改方式、验证结果与提交。仅已验证适用项打勾；确认不需修改的候选记录原因。

## 验证任务

- [x] V01 · 核对本轮修改路径的任务身份、终态和取消门禁；README / Skill 预览状态补充回归测试，探索详情的实际连续点击场景保留人工验收。
- [x] V02 · 运行相关定向测试；涉及状态管理 / 新 Swift 文件时按 Makefile 完成双渠道构建，不操作桌面。
- [x] V03 · 每个提交检查暂存内容与 `git diff --cached --check`，不夹带无关改动。
- [x] V04 · 回读提交历史、剩余修改与 checklist，给出仍待人工验证的场景。

### 人工验收

以下项目未执行；没有 GUI 操作授权或实机性能测量，不能以构建和状态测试通过代替。

- [ ] 大列表滚动与连续选中：在较多已加载行中快速滚动、悬停和跨行选择，确认正文不随背景弹簧拉伸，分页、键盘、多选和拖拽保持原行为。
- [ ] 长 Agent / RAG / Repo AI 会话：切换会话、查看流式内容和 Inspector，确认滚动位置、草稿及读取任务不因展示淡化反复重建。
- [ ] 快速 A → B → A：分别检查仓库 README、独立 Skill 条目及文件，确认当前内容正确、没有永久透明或迟到内容覆盖。
- [ ] 加载终态与恢复：慢网、空结果、需要登录、读取失败及重试后，骨架能够结束；已有缓存或同文件刷新保留可用正文。
- [ ] 探索 Star 请求：A 发起 Star 后立即选 B，等待 A 完成，确认 B 详情与 README 保持当前选择，A 的操作结果仍正确反映到列表。
- [ ] Reduce Motion：启用减少动态效果后，不出现跨行弹簧与整区模糊；淡化、加载终态及选择反馈仍可用。
- [ ] 明暗主题与视觉状态：检查斑马纹、整行 hover、彩色图标及语言色；确认选择、勾选和键盘聚焦可区分。

## 提交映射

| 任务 | 提交 | 结果 |
|------|------|------|
| P01 | `1815514c` | 行动画限定在背景、描边与指示条 |
| P02 | `a2e0c943` | 大型列表、时间线和含任务的展示区域保留宿主身份 |
| P03 | `4c195fb4` | README 空结果、登录提示与错误能够结束骨架 |
| P04 | `e8c893d7` | Skill 文件快速回切与失败时恢复保留正文 |
| P05 | `80af1862` | 七处新增展示索引不再逐行扫描集合 |
| P06 | `cb482a61` | Skill 页签不再额外复制整段内容容器 |
| P07 | `b947b919` | 旧 Star 请求完成不覆盖当前仓库详情 |

## 本轮自动化验证

收尾记录日期：2026-11-16。下表记录本轮修复后的实际结果；原专题实施阶段的 106 项测试与构建记录仍单独保留，不混算。多轮定向测试存在重复，测试数量不相加。

| 验证 | 结果 | 日志 |
|------|------|------|
| P03 定向测试 | 4 个 Suite、34 项通过 | `/tmp/starcat-list-detail-motion-p03-tests.log` |
| P04 定向测试 | 4 个 Suite、26 项通过 | `/tmp/starcat-list-detail-motion-p04-tests-rerun.log` |
| P05 定向测试 | 6 个 Suite、58 项通过 | `/tmp/starcat-list-detail-motion-p05-tests.log` |
| 最终定向测试 | 4 个 Suite、43 项通过，包含本轮新增的 8 个状态回归测试 | `/tmp/starcat-list-detail-motion-final-tests.log` |
| `make build-direct` | 构建与产物校验通过，未启动应用 | `/tmp/starcat-list-detail-motion-build-direct.log` |
| `make build-appstore` | 构建与产物校验通过，未启动应用 | `/tmp/starcat-list-detail-motion-build-appstore.log` |
| 提交与文档静态检查 | 七个修复提交的 `git log --check` 通过，专题 115 个本地 Markdown 链接目标存在 | 当前 worktree 的 Git 与文档检查结果 |

最终定向测试覆盖 `ReadmeHandoffTests`、`SkillPreviewHandoffTests`、`StarringSubsystemTests`、`ExploreDiscoveryViewModelTests`。状态归属和业务契约由测试校验；帧率、主线程停顿、内存峰值及动画观感仍需上方人工验收与实际测量。

七项修复的最终代码提交为 `b947b919`；性能修复阶段没有合并或推送。此前独立的 `Starcat/Features/Home/SidebarItem.swift` 图标改动未混入七个性能修复提交；验证记录与实施清单措辞更新由 `de07b6ce` 单独收尾。追加授权后的图标补交、集成与清理见下一节，专题不因合并而自动关闭。

## 合入 dev 与本地清理

授权与执行日期：2026-11-16。主工作区原为 `dev@2f59419c`，功能分支头为 `a0db1dd9`；合并提交为 `fd3c66b7`，后续实现与验收在主工作区继续。

- [x] M01 · 提交范围核对：独立洞察图标补交为 `a0db1dd9`，专题原实现及 P01–P07 提交全部保留；没有夹带其他 worktree 的工作。
- [x] M02 · 解决五处冲突：共享仓库行保留绘制层动画，探索详情同时保留当前快照回写与推荐反馈，Issues 保留相邻切换、滚动定位和编辑器逻辑；分支登记保留 dev 的现有记录。
- [x] M03 · 验证集成结果：9 个 Suite、145 项定向测试通过，Direct 与 App Store 均完成构建和产物校验；未启动应用或操作桌面。
- [x] M04 · 删除前检查：功能分支是 dev 祖先，`dev...codex/list-detail-motion` 为 `57 0`，`git cherry` 与三点 diff 为空；worktree 无未提交或未跟踪文件，Secrets 配置与主工作区一致，忽略文件无独有用户数据。
- [x] M05 · 非强制清理：通过 `git worktree remove` 和 `git branch -d` 删除 `Starcat-list-detail-motion` 与 `codex/list-detail-motion`；保留其他 worktree，未推送或操作远端。

| 集成验证 | 结果 | 日志 |
|------|------|------|
| `make test` 定向回归 | 9 个 Suite、145 项通过 | `/tmp/starcat-list-detail-motion-merge-tests.log` |
| `make build-direct` | 构建与产物校验通过，build-only | `/tmp/starcat-list-detail-motion-merge-build-direct.log` |
| `make build-appstore` | 构建与产物校验通过，build-only | `/tmp/starcat-list-detail-motion-merge-build-appstore.log` |

本次定向回归覆盖 `ReadmeHandoffTests`、`SkillPreviewHandoffTests`、`ReadmeWebViewTests`、`StarringSubsystemTests`、`ExploreDiscoveryViewModelTests`、`DailyRecommendationTests`、`RecommendationHistoryListTests`、`RepoIssuesViewModelTests`、`RepoIssuesWorkspaceViewModelTests`。这次结果与上方性能修复阶段的记录分开统计；人工验收项继续保持未勾选，不以合并或自动化结果替代。

## 修复与验证记录

### P01 · 行背景动画边界

触发：Agent 流式事件行的正文或高度更新与 hover / 选中同帧发生时，原先行根部 `.animation` 会把布局更新一并纳入动画。此次把动画下沉到绘制背景与 overlay，行内容不再接收这些新增交易。`git diff --check` 通过；该绘制改动没有对应单测，不额外构建或操作 GUI。真实滚动与选择观感待人工验收。

原专题测试和构建记录见实施 Checklist，不自动视为本轮修复后的验证结果。

### P02 · 大型宿主身份与单层交接

触发：原生 List、消息时间线、Repo 标题挂上 `nativeDetailTransition` 后，选择变化会通过 `.id` 重建子树；离场和入场并存期间可能重复创建滚动区、解析长正文或重启标题内的读取任务。改用 `stableDetailTransition`，只在选择变化时短暂降低现有树的不透明度并恢复，不复制长内容、不整区模糊。Agent 历史加载期间保留时间线宿主，在骨架下隐藏并禁用交互；RAG 沿用原有骨架交接。Skill 实际条目读取仍按条目身份重置。

这类宿主采用稳定树上的轻量淡化，替代保留两份长正文的交叉模糊；小型纯展示区域继续沿用原有完整出入场。检查没有新增随机身份、计时等待或业务任务；`git diff --check` 通过。无对应视觉单测，本轮后续状态修复的定向测试与双渠道构建一并核对编译。

### P03 · README 无文档终态

触发：同一仓库的 `.loading` 转为 `.empty`、`.requiresLogin` 或 `.error` 时，原任务 token 都是 `scope|unloaded`，SwiftUI 不会重启交接任务，骨架可能持续遮住终态。改为使用 `ReadmeStateView.HandoffKey`，以仓库范围、等待 / 文档 / 终态驱动交接；仅缓存时间或错误文案变化不重播，未对齐范围的旧状态继续等待。原文档 ready / failure 的双重身份校验、WebKit 失败重试代次和稳定宿主均保留。

新增 `ReadmeHandoffTests` 覆盖无文档终态、范围未对齐、缓存时间变化、重试身份与快速回切的任务归属。通过 `make test` 定向运行 `ReadmeHandoffTests`、`ReadmeWebViewTests`、`SkillContentReaderTests`、`AgentRunInspectorPresentationTests`：4 个 Suite、34 个测试通过。测试验证状态身份和既有读取 / 文档契约，未代替真实 WebView 导航与视觉验收。

### P04 · Skill 预览回切恢复

触发：B 的文件切换把 A 设为透明但尚未清空快照，此时回切 A 被视为同文件刷新；原逻辑只有读取成功才恢复可见，刷新失败后正文和错误一起留在透明层。将已有文件、正文、错误与可见性收为局部 `PreviewPresentation` 快照，开始同文件刷新时先恢复保留正文，不依赖成功回调。不同文件仍先退场再更新快照；读取并行、取消检查、请求身份与 loading 收口保持原有约束。

新增 `SkillPreviewHandoffTests` 覆盖中断退场后回切、同文件刷新、不同文件快照和首载边界。通过 `make test` 运行该 Suite、`SkillContentReaderTests`、`SkillWorkspaceTests`、`SkillWorkspaceSnapshotTests`：4 个 Suite、26 个测试通过。测试验证展示快照和真实文件读取，不冒充实际快速点击的视觉验收。

### P05 · 展示索引只枚举一次

触发：新增行底色在每行调用来源集合的 `firstIndex`，整批重算时反复线性扫描；Skill 来源 / Agent 名称的派生集合也被每行重新读取。改为在当前 `ForEach` 上枚举，并把行号传给绘制函数，消除七处新增扫描。`ForEach` 仍使用原业务 ID；洞察第二组接续第一组的展示索引，历史折叠沿用原有前缀顺序。标签编辑真正修改候选时的 `firstIndex` 保留，不扩大到业务重构。

通过 `make test` 运行 `AgentWorkspaceViewModelTests`、`AgentRunInspectorPresentationTests`、`InsightsModelsTests`、`InsightsDrillDownTests`、`SkillWorkspaceTests`、`TagTaxonomyBootstrapServiceTests`：6 个 Suite、58 个测试通过。本项没有新增仅复刻枚举实现的测试；实际行配色、懒加载滑动与流畅度仍待人工验收。

### P06 · 骨架时钟和 Skill 页签边界

`ListLoadingSkeleton` 每组只使用一个既有 `SkeletonAnimatedPhase`，没有新增逐行计时器；列表 / 详情骨架由加载分支挂载，Reduce Motion 时使用静态 phase。仓库 Skills 安装窗口与 RAG 的既有交接保持原实现。

Skill 内容页已有条目级交接、文件退场及独立加载任务，overview / files 页签原先再用 `nativeDetailTransition` 给整段内容换身份并模糊。此次只把这一层改为稳定身份的轻量淡化，避免额外复制内容容器；读取任务和展示快照仍由外层持有。其余小型纯展示详情没有发现需重复修改的同类任务归属问题。`git diff --check` 通过，无对应页签动画单测；编译随后续双渠道构建核对，视觉效果保持待验收。

### P07 · 探索详情 Star 完成后的展示归属

触发：A 发起异步 Star 后选择 B，A 的回调仍持有旧 `repo` 和 `item`；稳定宿主使其原先的 `displayRepo = oldRepo`、`resolveRepo()` 与 `loadReadmeIfNeeded()` 能重新覆盖当前详情并读回旧 README。完成后改为对当前 `displayRepo` 应用 Registry 展示状态，然后沿用全局列表刷新；不把旧选择重新写入，也不新增一套请求协调器。

通过 `make test` 运行 `ReadmeHandoffTests`、`SkillPreviewHandoffTests`、`StarringSubsystemTests`、`ExploreDiscoveryViewModelTests`：4 个 Suite、43 个测试通过，涵盖本轮新增的 8 个状态回归测试及已有 Star / 探索契约。此处未为简单的当前快照更新新增抽象或测试替身；A Star → 切 B → A 请求返回的真实界面顺序仍列入人工验收，测试不证明 GUI 无闪回。
