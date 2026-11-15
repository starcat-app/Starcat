# 列表与详情动效实施 Checklist

> 状态：82 个场景源码核对与适用改造、106 项定向测试及双渠道构建校验已完成；后续性能修复见[性能与动画修复 Checklist](性能与动画修复Checklist.md)，人工视觉验收待进行，专题保持开放。
> 授权与日期：2026-11-15，dong4j 要求基于本地 dev 使用独立 worktree 完整执行专题，先建清单、逐项看代码，避免重复实现。
> 基线：`dev@b91e22c1`；分支：`codex/list-detail-motion`。
> Worktree：`/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-list-detail-motion`。
> 范围来源：[方案与原始 Checklist](列表与详情动效优化方案与Checklist.md)；效果标准：[列表与详情规范](../../5-规范/UI-列表与详情切换动效规范.md)、[通用动效规范](../../5-规范/UI-动效规范.md)。

勾选表示已核对源码并完成该项适用的代码工作，不代表人工视觉验收通过。“已有”必须记录实际实现依据，“不适用”必须说明交互语义。没有核对的项保留未勾选；测试、构建、人工验收分别登记。

## 1. 范围与准备

- [x] 使用本地 dev 最新已提交内容建立独立 worktree；主仓库未提交文档不带入。
- [x] 复制被忽略的 `Configs/Secrets.xcconfig`，不输出、不提交内容；使用本分支受控 SPM 锁。
- [x] 登记 BRANCH；主窗口 `SidebarView` 最左侧分类导航明确排除。
- [x] 基础-01：对照推荐分支，只移植 `RepoRowSurface` / `UnifiedRepoRow` 的 namespace 能力；保留 dev 新增的笔记标记等字段。
- [x] 基础-02：Repo、中栏搜索、RAG、Agent、知识库与各管理窗口分别持有 namespace；批量多选不共享滑块，键盘聚焦独立保留。
- [x] 基础-03：复用 `SkeletonAnimatedPhase`、`SkeletonPalette`、现有正文 / 文件骨架；增加少量行骨架组合，WebView 沿用 `documentID` ready / failure 回调。
- [x] 基础-04：`ListRowSurface` 只绘制条纹、hover 和单选背景；局部原生展示使用 `nativeDetailTransition`，业务与导航仍由各页面持有。
- [x] 参考回归（源码）：设置页主菜单、详情过渡、彩色图标及保存路径保留；本次只补其语言候选行反馈。
- [x] 参考回归（源码）：仓库 Skill 安装窗口已有共享选中、退场快照、完成回调、当前文档 ready 和两侧骨架；不改 `RepoSkillSelectionPane` / `RepoSkillDetailPane` 主流程。

## 2. A：重点工作台

- [x] A01 · RAG 会话 → 对话中栏 — 置顶 / 分组 / 未分组共用当前 rail 的选中背景；正文使用稳定宿主上的轻量淡化，保留原有会话骨架交接和请求隔离，性能修复见 P02。
- [x] A02 · RAG 上下文仓库多选 — 候选传递展示索引补条纹；保留已有候选骨架，勾选与键盘聚焦分别表达，不传单选 namespace。
- [x] A03 · RAG 入库候选 — 空候选初载改行骨架，刷新保留候选；多选行统一条纹 / hover，入库真实进度保留。
- [x] A04 · Inspector 引用、远程来源、排行 — 已有 `LocalHoverSurface` 与条纹；引用为手风琴，保留展开与跳转语义。
- [x] A05 · 检索候选、重排、命中 — 已有条纹 / 局部 hover 和当前请求数据，不虚构持续选中；真实检索进度保留。
- [x] A06 · 索引覆盖、trace、事件、当前分片 — 保留 trace payload 骨架；元数据与当前分片初载补行骨架，已有信息行反馈保留。
- [x] A07 · 引用及两类 XML 弹层 — 三处已复用 `RAGPopoverSkeletonHandoff(contentID:)`，按引用取消旧任务后交接；保留正文 / XML 对应骨架。
- [x] A08 · Agent 目录、历史任务 → 工作区 — 两组列表独立共享背景；补历史首载和读取详情骨架、工作区交接；读取序号隔离迟到快照，等待期间禁止向旧任务提交。
- [x] A09 · Agent 上下文仓库多选 — 候选展示索引传给紧凑 Repo 行；已有初载骨架保留，多选及键盘高亮不共用单选滑块。
- [x] A10 · 产物列表 → 详情 — 独立 namespace，产物详情局部过渡；产物来自运行内存快照，无异步正文读取，不造假骨架。
- [x] A11 · 过程 / 消息事件 → Inspector — 过程及消息事件行共享各自列表背景；Inspector 按事件身份交接，流式任务与滚动宿主保留。
- [x] A12 · 知识引用、审计证据 — 引用信息行补条纹 / hover；审计按 `selectedToolCallID` 交接，外链不增加持续单选。
- [x] A13 · Inspector 仓库、附件、链接 — 三类信息行补条纹 / hover，信息来自已加载 Run 快照；打开附件和外链不增加持续选择。
- [x] A14 · 知识库仓库 → 索引详情 — Repo 列表接共享背景，初载两栏骨架；详情数据记录归属仓库，成功或失败均结束当前占位，避免新标题搭配旧分片。
- [x] A15 · 检索测试 → 命中 — 未有命中时显示结果行骨架与过渡，保留真实检索按钮进度、评分及命中定位。
- [x] A16 · 分片列表 → 编辑弹层 — 已有条纹、局部 hover 与系统 sheet；保留编辑器及未保存内容，不增加虚假的右侧单选滑块。
- [x] A17 · 元信息与 XML 预览 — 元信息随当前仓库数据一并交接；XML 已有异步骨架与内容身份检查，保留生成 / 索引实际进度。
- [x] A18 · 独立 Skill 分类、Agent、来源 → 中栏 — 原生 `List(selection:)` 保留，三组导航共用当前侧栏 namespace；中栏按导航局部交接。
- [x] A19 · 独立 Skill 中栏多选 → 当前详情 — 首载改行骨架，条纹 / hover 与每项多选态保留；当前模型仅单选时展示正文，多选进入原有批量占位，不虚构当前项。
- [x] A20 · 独立 Skill 详情 tabs — 条目、页签采用保留容器身份的轻量淡化；状态留在外层，概览与文件继续复用同一内容视图，不额外复制整段正文，性能修复见 P02 / P06。
- [x] A21 · 独立 Skill 文件 → 预览 — 文件列表单选共享背景；清单与正文骨架，读取和旧页退场并行，完成回调后换正文；同文件刷新保留旧内容，取消 / 错误均结束等待。

## 3. B：中栏、搜索与洞察

- [x] B01 · 星标、筛选、知识库、项目中栏 — Repo 单选 namespace，多选时传 nil；卡片颜色、拖拽与分页保留，共用详情按 B13 处理。
- [x] B02 · 探索仓库 — Repo 单选 namespace，Discovery 原生区域按条目交接；阅读器复用 B13，已有列表骨架保留。
- [x] B03 · Awesome 项目 — 接共享 Repo 行和 Discovery 详情；不更改来源 / 分类与分页。
- [x] B04 · Linux.do 项目 — 接共享 Repo 行和 Discovery 详情；保留来源标识及原帖操作。
- [x] B05 · 趋势 — 接共享 Repo 行与 README 交接；保留周期、分页与语言色。
- [x] B06 · 动态及特殊活动行 — 仓库行与特殊活动行复用同一 Repo 表面和当前列表 namespace，移除重复私有表面；详情沿用共享过渡，时间轴结构保留。
- [x] B07 · 周刊项目 — 接共享 Repo 行与共用详情；保留来源筛选、分页及已有骨架。
- [x] B08 · 取消 Star 记录 — 单选共享背景，多选保持每项独立选中；共用详情与恢复操作保留。
- [x] B09 · Search Center → 详情 — 仓库 / 网页共享当前结果 namespace，保留已有结果骨架和请求隔离；局部原生详情及稳定网页阅读器保留，不合并不同结果类型的任务身份。
- [x] B10 · GitHub 通知 → 详情 — 时间轴行补条纹 / hover / 跨行背景，初载行骨架；通知详情按 thread 身份交接，原有消息 / README 加载路径保留。
- [x] B11 · 洞察主题 → 内容 — 原生导航行补共享背景，主题与详情采用 240ms 局部交叉过渡，减少动态时 120ms 淡化。
- [x] B12 · 优先仓库、排行、行动项 — 行补条纹 / hover；首载指标、图表和行动行骨架，已有快照刷新保留；行动项跳转当前洞察内容，不增加虚假持续选择。
- [x] B13 · 共用 Repo 详情与稳定 WebView — 原生展示复用交叉模糊过渡；非 Manage 的 README 补展示快照、退场完成、当前 `documentID` ready / failure 和重试身份；Manage 沿用既有协调器，Scaffold / WebView 宿主保持稳定。

## 4. C：管理与审核

- [x] C01 · 文件树 → 预览 — dev 已有树形骨架、共享选中、`presentedPreview` 快照及动画完成后发布、Markdown ready 校验；保留本轮已合入能力，不重做。
- [x] C02 · Issues → 详情 — 复用已有列表骨架，行补条纹 / hover / 共享选中；详情由原透明度切换补为交叉模糊过渡，保留帖子快照、编辑器及真实评论状态。
- [x] C03 · 标签管理、编辑、合并 — 多选行与合并候选补反馈，合并单选独立 namespace；仅空列表加载时显示骨架，编辑器按原标签身份局部交接。
- [x] C04 · 标签体系候选 → 证据 — `focusedCandidateID` 与候选勾选保持独立，当前证据补局部过渡；候选来自已完成预检快照，不添加假加载。
- [x] C05 · 批量 AI 队列、审核 — `BatchAITagReviewRow` 已有条纹 / 140ms hover 与展开审核；真实生成 / 应用进度保留。
- [x] C06 · AI 分组预检规则 — 规则标题行补 hover，展开收起动画读取统一 Reduce Motion；保留规则卡片、编辑状态与延迟保存任务。
- [x] C07 · AI 分组结果、多选 — 结果行与多分组候选补条纹 / hover，保留每项勾选、分页和真实审核进度。
- [x] C08 · Repo AI 历史 → 对话 — 历史行共享当前列表背景，消息展示按 session 局部过渡；加载任务、流式会话与草稿状态留在原有宿主。
- [x] C09 · Repo AI 标签、引用 — 外部引用行补条纹 / hover，标签候选已有底色反馈补平滑 hover；流式标签和文本继续显示实际输出。
- [x] C10 · Skill 批量更新 → 差异 — 左侧单选共享背景，右侧差异 / manifest 局部过渡，首次准备改骨架；执行进度保留。
- [x] C11 · Skill 批量分配 — 目标多选及结果补条纹 / hover，初载准备骨架，真实提交进度保留。
- [x] C12 · Skill 更新审核 — 差异 / 分配行反馈，manifest 局部过渡，初载骨架；确认行为保留。
- [x] C13 · Skill 移除审核 — 分配影响行补反馈，初载骨架与真实移除进度分开。
- [x] C14 · Skill 分配 — 已发现位置与实际分配行补反馈；首读目标 / 观察结果使用骨架，刷新保留内容，服务不可用也结束占位；真实提交 / 暂停 / 移除进度保留。
- [x] C15 · 已有安装窗口辅助 Inspector — 目标、队列、冲突补条纹 / hover；不重做已完成主列表 / 阅读器，保留实际安装、取消与重试。
- [x] C16 · AI 模型管理 — 模型行补条纹 / hover；保留 `AIModelFixedHeightHost` 与搜索状态。
- [x] C17 · 本地模型目录、下载 — 模型目录行补条纹 / hover；选择后弹层关闭，无持续单选；真实下载 / 校验进度保留。
- [x] C18 · 翻译语言包 — 首次查询改骨架；原生交替底色保留，行补 hover；Apple 下载与可用性语义保留。
- [x] C19 · CC Switch 导入 — 四类结果保留原生 `alternatesRowBackgrounds`，补整行 hover；预览 / 进度 / 结果局部交接，多选和导入进度保留。
- [x] C20 · MCP / Pro 设备 — 设备行补条纹 / hover；Direct Pass 首次远程查询补行骨架，MCP 本地设备快照继续即时显示，解绑 / 授权不改。
- [x] C21 · AI 用量维度、原生 Table — 首帧六张指标卡、趋势图、明细骨架；维度行补反馈，保留原生 Table、排序与已有数据刷新。

## 5. D：小弹窗与信息行

- [x] D01 · 三处语言搜索选择 — 设置、主列表、RAG 搜索候选均补行反馈；多选不传共享 namespace，设置主导航不改。
- [x] D02 · 标签选择 — 首载骨架及候选条纹 / 多选 / hover，删除整窗旋转覆盖。
- [x] D03 · 智能集合多选 — Toggle 行补条纹 / hover，保持多选绑定。
- [x] D04 · CodeFlow / 文件浏览分支选择 — 两处候选补条纹 / hover；选择后关闭弹层，不虚构持续详情导航，实际分支加载保留。
- [x] D05 · 后台任务 — 任务行补条纹 / hover；任务真实进度保留。
- [x] D06 · 本地 AI 状态 — 模型及 Laya 行补条纹 / hover，保持实际加载状态。
- [x] D07 · 外部 Star 收件箱 — 实际是叠放头像胶囊入口，没有独立行列表；不适用条纹 / 单选滑块。打开后的批量确认列表由 D18 覆盖，头像沿用 `RemoteAvatar` 占位。
- [x] D08 · 贡献者 — 信息 / 外链行补条纹 / hover，无持续详情选择。
- [x] D09 · 健康度 — 首次主体加载改骨架，事实行补条纹 / hover，评分进度保持真实数据。
- [x] D10 · OpenSSF — 首次检查列表改骨架并补行反馈，雷达图保持原形态。
- [x] D11 · 发布历史、资源 — 初载骨架、刷新保留历史，发布行反馈；资源已用带 index 的 `ReleaseAssetRowView`。
- [x] D12 · 周刊来源事件 — 来源事件行补条纹 / hover，不改变展开 / 跳转。
- [x] D13 · 两处动态发布资源 — 两处均复用 `ReleaseAssetRowView(rowIndex:)`，已有条纹 / hover，保留。
- [x] D14 · 洞察内部信息列表 — 安全公告 / 时间线补条纹与平滑 hover；贡献者及发布资源已有对应行反馈和资源行组件，保留现有正文加载骨架。
- [x] D15 · 关于、依赖 — 保留 segmented，正文局部过渡，依赖行补条纹 / hover。
- [x] D16 · 推荐弹窗 — 卡片复用 `UnifiedRepoRow`，一次性打开无持续单选；已有五张骨架补共用动画时钟及内容交接，追加加载保留实际进度。
- [x] D17 · 热点关联项目 — 保留卡片 hover、打开路由和项目面板；已知仓库身份保持可见，仅等待统计元数据时补局部动态骨架。
- [x] D18 · 批量 Star 预览 — 预览仓库行补条纹 / hover，批量确认不增加选择滑块。
- [x] D19 · 取消 Star 数据选择 — 删除影响行补条纹 / hover，保留各项选择及确认。
- [x] D20 · Profile 组织入口适用性 — 横排头像、溢出原生 Menu，已有 hover 与头像占位；不适用普通行条纹 / 单选滑块，不扩大到主侧栏。

## 6. E：特殊形态

- [x] E01 · 热点网格、历史、阅读器 — 卡片 hover、历史条纹及 `DailyRadarPreviewReader` 当前文档 ready 后骨架交接已存在；保留网格和阅读器，不重做。
- [x] E02 · 智能集合网格 — 已有卡片 hover 与打开反馈，内容源为本地集合快照；保留卡片空间语义，不套行条纹或制造异步占位。
- [x] E03 · 智能集合瀑布流 — 已有瀑布流骨架、卡片反馈及结果交接；保留布局、筛选与分页，不变更为单选行列表。
- [x] E04 · Awesome 来源网格 — 保留多选卡片与现有 hover；初载补同两列、同 222pt 高度的动态卡片骨架，刷新保留勾选。
- [x] E05 · 图谱搜索 → 定位 — 内存图谱搜索无远程等待，结果行补条纹 / hover；当前节点卡片沿用局部内容过渡，镜头与画布保留。
- [x] E06 · RAG 大纲 rail — 已有小横线 hover、当前消息标记及预览；按滚动定位语义保留，不改成会话列表。
- [x] E07 · 说明、原生控件等不适用项 — 纯说明、提示词占位符、权限 scope、徽章、Menu / Picker、图表 / 日历 / 聊天均不批量套滑块，真实业务进度保留。

## 7. 验证与交付

- [x] 全部 82 个场景均有源码核对与处理记录；脚本验证编号集合完整、无重复、无“待核对”项。
- [x] 单选背景仅在绘制层共享几何身份；多选、键盘、拖拽、分页原有调用保留，实际操作验收另列。
- [x] 详情交接检查展示身份、取消与 ready / failure 路径；错误 / 空态可结束占位，实际连续切换待实机查看。
- [x] 首载复用对应布局骨架；已有结果刷新保留内容；新代码没有使用固定 `sleep` 制造等待。
- [x] Reduce Motion、主题与彩色图标源码检查；共享表面不重写前景色，骨架时钟读取统一环境。
- [x] 定向测试：12 个 Suite、106 项通过，命令及边界见下表。
- [x] 新增 Swift 文件及展示状态改动已通过 `make build-direct` / `make build-appstore` 最终构建与产物校验，未启动应用。
- [x] `git diff --check`、专题本地链接与清单完整性检查通过。
- [x] `SidebarView`、`RepoSkillSelectionPane`、`RepoSkillDetailPane` 没有 diff；设置改动仅涉及语言候选行。
- [ ] 人工视觉验收（需 dong4j 查看；当前无 GUI 操作授权）。
- [x] 授权边界已落实：保留当前 worktree 与分支；2026-11-15 获准本地提交原实现基线与逐项性能修复，不合并 / 推送，未改 Changelog 或 `docs/功能实现总览.md`。

### 验证记录

| 类型 | 范围 / 命令 | 结果 | 边界 |
|---|---|---|---|
| 源码 | A01～A21、B01～B13、C01～C21、D01～D20、E01～E07 | 82 项已核对并记录适用处理 | 包含复用已有实现与不适用项；不等于视觉验收 |
| 自动化 | `make test`，下列 12 个 Suite | 106 项通过，0 失败 | 覆盖 Agent 状态 / 事件 / 历史、Skill 读取 / 快照 / 会话及 RAG 历史等；没有自动验证视觉观感 |
| 构建 | `make build-appstore` 最终增量 | 构建与产物校验通过 | 稳定版 Xcode，App Store / 沙箱专用缓存；未启动应用 |
| 构建 | `make build-direct` 最终增量 | 构建与产物校验通过 | 初轮依赖拉取中断已恢复；Direct 专用缓存，未启动应用 |
| 静态 | `git diff --check`、82 项集合检查、Markdown 本地链接检查 | 通过 | 主侧栏 / 安装窗口主流程 / 受控 SPM 锁 / 国际化目录 / 主总览无 diff |
| 人工 | 待 dong4j 查看 | 未执行 | 未进行视觉验收；曾误调用环境枚举后立即停止，未截图或读取 AX |

### 定向测试命令

```bash
make test TEST_ARGS="\
-only-testing:StarcatTests/AgentWorkspaceViewModelTests \
-only-testing:StarcatTests/AgentRunInspectorPresentationTests \
-only-testing:StarcatTests/AgentHarnessProcessTests \
-only-testing:StarcatTests/AgentTimelineProjectionTests \
-only-testing:StarcatTests/AgentRunRepositoryTests \
-only-testing:StarcatTests/SkillContentReaderTests \
-only-testing:StarcatTests/SkillWorkspaceSnapshotTests \
-only-testing:StarcatTests/SkillWorkspaceTests \
-only-testing:StarcatTests/SkillLibraryEnvironmentTests \
-only-testing:StarcatTests/RepoSkillRowChromeTests \
-only-testing:StarcatTests/AIUsageDashboardViewModelTests \
-only-testing:StarcatTests/RAGConversationHistoryWindowTests"
```

日志：`/tmp/starcat-list-detail-motion-tests.log`、`/tmp/starcat-list-detail-motion-build-direct-final.log`、`/tmp/starcat-list-detail-motion-build-appstore-final.log`。这些是本次本地验证日志，不能代替后续提交与人工验收记录。
