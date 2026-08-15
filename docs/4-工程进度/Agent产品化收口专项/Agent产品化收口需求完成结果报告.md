# Agent 产品化收口需求完成结果报告

- 报告时间：2026-08-15 14:22 CST
- 当前分支：`dev`
- 专项范围：权威设计 P0～P4；P5 外部 CLI Runtime 不在本轮范围
- 当前状态：仓库内工程实现、真实窗口视觉验收与历史真实 Run 数据闭环完成；Debug 数据容器仍受既有对话模型配置门禁限制，真实分发产物双渠道验收等待发版授权

## 1. 项目目标

把 Starcat 已有 Agent 从可运行功能收口为可发布候选：保持 Agent 与 RAG 两个产品独立，只复用 Composer、Markdown、知识检索和领域 Capability；完成失败与中断恢复、Agent/MCP 能力复用、产品门禁、Run Surface、国际化、测试、文档和多轮审查，不开放 Shell、文件编辑、浏览器自动化、subagent 或无人值守写入。

## 2. 完成内容

### 2.1 Run 恢复与重试

- 失败 Run 可在同一 Run ID 中恢复上下文、预算、usage、sequence 与 Artifact 计数后安全重试。
- 重试原子清除旧错误与终态时间，保留完整消息和审计链。
- 已执行写工具不重放；未决写审批或不可恢复附件上下文 fail closed。
- App 异常退出遗留的 `planning` / `running` 在 Workspace 首次加载历史时收口为可重试失败态。
- `waitingForConfirmation` 保持审批恢复，completed / failed / cancelled 终态不被启动恢复改写。

### 2.2 Agent / MCP 统一能力

- Agent 与 MCP 标签写入复用同一 Repository Tag Capability 装配点、权限、dry-run 和 read-back 语义。
- Agent 写后恢复语义索引刷新；MCP 仓库解析复用 Repository Read Capability。
- Note / Status 继续使用共享 Metadata Capability；未为内置 Agent 臆造当前不使用的 adapter。
- 内置 Agent 不依赖 MCP listener、端口或 API Key。

### 2.3 产品门禁与正式入口

- 移除 `DebugFlags.agentToolbarEntry`，Agent 工具栏入口进入 Debug / Release 与 App Store / Direct 共用产品路径。
- 入口继续经过 AI Chat Pro 权益和已配置对话模型门禁。
- 修复门禁失败仍误记新手引导完成，以及 Agent 误用 RAG 模型提示文案。
- Getting Started 增加 Agent 正式步骤。

### 2.4 Run Surface

- 按 `toolCallID` 合并 call/result，相邻同类工具按稳定 `presentationKey` 聚合。
- Approval、失败和用户可见进度形成 Activity Group 边界。
- 运行 / 审批 / 失败默认展开，完成 / 取消 / 历史完成默认折叠，并尊重用户手动折叠。
- 中栏采用右侧浅灰用户消息、单一 Agent 身份、纵向“任务进展”和自然语言活动的连续叙事，不再使用大卡片嵌套。
- 工具 `output.log` 作为用户可读 narrative；英文内部工具名、raw JSON、input/output、`elapsed_ms` 等技术元数据不进入普通产品 UI。
- 最终回答和 Markdown Artifact 在中栏作为连续正文渲染；Artifact 一级标题与文档标题相同时自动去重。
- 普通 UI 不展示模型 raw reasoning；用户上滚后流式更新不抢回位置。
- Activity Group 可直接定位 Knowledge Audit。
- Run Header 明确限制为 60pt 紧凑高度并移除开发者副标题，消除竖向 Divider 导致的半屏拉伸。
- 新增真实 `NSWindow + NSHostingView` 像素渲染测试，避免 `ImageRenderer` 对 LazyVStack 产生全白截图仍假通过。

### 2.5 Composer、仓库与国际化边界

- Agent Composer 复用共享输入组件，同时保持 Agent 的固定工作流与 RAG 问答语义分离。
- `@` 只触发仓库选择面板，不写入正文；多选、清空、排序、筛选和多来源逻辑与既有 RAG 交互一致。
- 仓库目录覆盖 `repos + Weekly + Trending + Discovery`，Star 与知识库只作为筛选维度，80 条只是上屏窗口。
- Agent 新增和既有 key 全部覆盖 18 locale，目录内没有 `String(localized:)` / `NSLocalizedString` 违规调用。

### 2.6 真实联网、产物与运行性能

- Artifact Agent 在迭代预算耗尽前进入 Definition 驱动的最终提交回合，确保成功 Run 产生结构化产物。
- External Search 的多批成功结果在运行与恢复路径统一累积；Repo Alternatives 使用完整证据校验候选，但最终来源区只保留候选 GitHub 根 URL。
- Run 展示问题与下一次 Composer 草稿分离，发送、完成刷新和历史回看均不会把已发送问题重新填回输入框。
- Provider 原始正文 / reasoning delta 先在 Runtime 按 100 ms 时间窗合并，再进入 `MainActor`；Workspace 展示层继续按时间和字符阈值节流并限制尾部长度。
- Run Surface 复用 `ScrollTailController` 与 `sizeChanges` anchor，移除状态 / 正文变化触发的同步 `scrollTo`，修复长工具链完成后 `GraphHost.flushTransactions` 持续占用主线程的布局风暴。

## 3. 功能清单

| 功能 | 状态 | 主要证据 |
|---|---|---|
| 失败 Run 同 ID 安全重试 | 完成 | Runtime / Session / Repository / ViewModel 测试 |
| 进程中断遗留 Run 收口 | 完成 | `c870dd4`、40 项定向测试 |
| 等待审批恢复与写入 fail closed | 完成 | Approval / Retry 测试 |
| Agent / MCP 共享领域 Capability | 完成 | Capability / MCP 契约测试 |
| 正式入口、Pro 与模型门禁 | 完成 | 真实入口 UI + Release build |
| 连续任务叙事 Run Surface | 完成 | 36 项定向测试 + 真实窗口像素渲染 |
| Markdown Artifact 与 Inspector | 完成 | 连续正文、标题去重、Knowledge Audit + Debug build |
| 18 locale 国际化 | 完成 | JSON 完整性检查，0 缺失 / 空值 / 非 translated |
| 真实 Provider 历史闭环 | 完成 | 最终代码真实 Run、历史回看与 Artifact 持久化 |
| 最终代码完整 Run Surface 视觉验收 | 完成 | 生产视图真实 `NSWindow` 渲染与像素断言 |
| 成功 External Search / GitHub Run | 完成 | 多批成功搜索共同校验 3 个候选仓库 |
| App Store / Direct 真实分发产物验收 | 待发版环境 | 两个 Release scheme 已编译，未获授权执行打包脚本 |

## 4. 文档同步情况

- 权威设计：`docs/3-设计/详细设计/57-Agent工作台与统一能力层详细设计.md`
- 设计索引：`docs/3-设计/详细设计/README.md`
- 前置决策：`docs/1-立项/开发前问题清单.md`
- 主进度：`docs/功能实现总览.md`
- 专项 checklist：`docs/4-工程进度/Agent产品化收口专项/checklist.md`
- 审查报告：`docs/4-工程进度/Agent产品化收口专项/审查报告/`（第 1～12 轮）

上述文档已同步当前 P0～P4 实现、P5 非目标、Agent/RAG 产品边界、全量仓库来源、能力复用、进程中断恢复和人工门禁。功能总览只更新已实现且有自动化或构建证据的条目。

## 5. 测试情况

- Repository / ViewModel 中断恢复定向测试：40 项，0 failed。
- Agent / Capability / MCP 定向测试：通过。
- 最终 Run Surface 定向测试：36 项，0 failed、0 skipped；`Test-Starcat-2026.08.14_12-53-14-+0800.xcresult`。
- StarcatTests：2,291 项，0 failed、8 skipped、1 expected failure。
- 最终全量测试结果：`Test-Starcat-2026.08.15_14-30-41-+0800.xcresult`。
- Runtime warnings：4 条，均来自既有 `DiagnosticsTests.swift` 后台发布，与 Agent 改动无关。
- 2026-08-15 卡死修复定向测试：`LoopAgentRuntimeTests`、`AgentWorkspaceViewModelTests`、`ScrollTailControllerTests` 通过；覆盖 400 个 Provider delta 的内容完整性、事件数量上界与生产视图渲染。
- Debug build：通过。
- App Store `Starcat` Release `CODE_SIGNING_ALLOWED=NO` build：通过。
- Direct `StarcatDirect` Release `CODE_SIGNING_ALLOWED=NO` build：通过。
- Direct Debug 最新构建：通过，bundle ID `com.starcat.app.direct.debug`；启动后 Agent 入口被既有“未配置对话模型”产品门禁拦截，未绕过门禁或填写用户凭据。
- 最新 Run Surface 使用同一生产视图在真实 `NSWindow + NSHostingView` 中完成视觉检查与像素断言；历史真实 Run 继续证明 Provider、消息和 Artifact 数据闭环，两类证据不互相替代。

## 6. 真实数据与隐私验证

只对当前用户 v19 数据执行只读聚合查询，没有读取或记录 Prompt、Artifact 正文、仓库名称或密钥：

- 最终代码真实 Run `B5B9A14A-E616-4EE4-AC7A-536D8EF42F4F` 在约 31 秒完成 10 条消息和 1 个 Markdown Artifact。
- Knowledge Search 有完成记录与 citation/source 事实。
- 5 个 Run 使用私有上下文；其中外部搜索保持 skipped，知识库检索可在冻结范围内完成。
- 公开仓库上下文下的多批 External Search 均成功，完整证据共同校验 `zed-industries/zed`、`neovim/neovim`、`helix-editor/helix`；私有上下文仍保持 fail closed。
- 最终 Artifact 为 2,779 字符，来源区只包含 3 个候选仓库根 URL；UI 导出文件为 `starcat-agent-alternatives-r606.md`（54 行、4,975 bytes）。
- 真实数据暴露的 2 个遗留 running Run 已通过 `c870dd4` 的进程中断恢复修复。

## 7. 审查轮次

| 轮次 | 重点 | 结论 |
|---|---|---|
| 第 1 轮 | 终态跟随、Knowledge Audit、总览漂移 | 发现并修复 |
| 第 2 轮 | 失败 / 等待 / 取消 / Approval 边界测试 | 发现测试缺口并补齐 |
| 第 3 轮 | i18n、全量测试、Release、权限与 schema | 仓库内无新问题，登记人工门禁 |
| 第 4 轮 | 真实 v19 数据与异常退出恢复 | 发现假运行态并以 `c870dd4` 修复 |
| 第 5 轮 | 修复后代码、文档、测试、渠道构建 | 未发现新的仓库内问题 |
| 第 6 轮 | 解锁后的真实 Provider、联网、视觉、历史与导出复验 | 发现并修复最终提交、证据累积、草稿恢复、产物噪声与运行卡顿 |
| 第 7 轮 | 最终文档漂移与最新代码测试 / 构建证据 | 文档已修复，2,286 项测试和三个目标构建通过 |
| 第 8 轮 | 修复后文档、代码、测试、进度与真实验收复审 | 未发现新的仓库内问题，仅保留分发授权门禁 |
| 第 9 轮 | Run Header 首屏高度与真实窗口复验 | 发现半屏拉伸并以 `113912d` 修复 |
| 第 10 轮 | WorkBuddy 原型对齐、任务叙事、Markdown 正文与视觉门禁 | 发现调试面板方向错误和空白截图假通过并以 `bffcf9a` 修复 |
| 第 11 轮 | 修复后代码、文档、i18n、定向与全量测试终审 | 未发现新的仓库内遗留问题，仅保留分发授权门禁 |
| 第 12 轮 | 长工具链完成后主线程卡死、入站增量与尾部跟随复审 | 发现同步 `scrollTo` 布局风暴并修复，定向回归通过 |

## 8. 本地提交

专项按独立功能使用中文 commit 提交，核心提交包括：

- `4dd3ae6` 建立专项清单。
- `056831c` 失败 Run 持久化重试。
- `fa759d1` Agent / MCP 能力装配统一。
- `e421a42` 正式入口与产品门禁。
- `8f064c2` 过程 / 结果双层运行界面。
- `b7ba314` 终态跟随与审计联动修复。
- `fd6a349` 状态与审批边界测试。
- `557b67a` 第三轮终审。
- `c870dd4` 进程中断恢复。
- `6680524` 第四轮真实数据审查。
- `bb026ad` 第五轮修复后终审。
- `36c5223` 最终回合结构化产物。
- `95975d5` 运行问题与输入草稿状态分离。
- `f81a78f` 多批联网搜索证据累积。
- `eaae375` 替代品产物来源区精简。
- `00ec878` 流式输出与自动滚动节流。
- `e6f18dc` FlowLayout 对齐递归修复。
- `30cb1e9` 第六轮真实复验报告。
- `adbbf22` 真实联网与产物验收回填。
- `97ad3f1` 历史审查环境门禁关闭。
- `113912d` Run Header 首屏高度修复。
- `bffcf9a` 连续任务叙事流、自然语言活动和 Markdown 正文重构。
- `cae7dec` 第十轮原型对齐审查与文档同步。

没有执行 push。

## 9. 遗留问题

1. 需要在获得发版授权后，按既有 SOP 生成 App Store / Direct 真实分发产物并分别验收；本专项没有执行打包、签名、公证或上传。
2. 全量测试保留 4 条既有 Diagnostics runtime warning，均来自 `DiagnosticsTests.swift` 的后台发布，不属于 Agent 专项，未借本轮做相邻重构。

## 10. 最终完成状态

仓库内代码、设计、专项 checklist、功能实现总览、国际化、Agent 定向测试、2,291 项全量测试、Debug / 双 Release scheme 构建、历史真实 Provider / External Search 数据闭环，以及最新连续任务叙事 Run Surface 的真实窗口渲染验收均已完成并一致。2026-08-15 新增的 Runtime 入站增量合并与安全尾部跟随已完成定向回归。

当前还保留两个外部门禁：Debug 数据容器需由用户配置对话模型后复验真实历史任务页面，App Store / Direct 真实分发产物需获得发版授权后按既有 SOP 分别验收。在未获授权前，不绕过产品门禁，不以离屏窗口、无签名 Release 编译替代这些外部验收。
