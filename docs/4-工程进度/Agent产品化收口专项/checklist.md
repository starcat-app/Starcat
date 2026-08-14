# Agent 产品化收口专项 Checklist

> 状态：工程、真实窗口视觉验收与历史真实 Run 数据闭环完成；Debug 历史页面复验等待模型配置，真实分发验收待授权
> 创建：2026-08-14
> 权威设计：`docs/3-设计/详细设计/57-Agent工作台与统一能力层详细设计.md`
> 目标范围：完成权威设计 P0～P4 与 Definition of Done，不扩张到 P5 外部 CLI Runtime。

## 1. 项目目标

把已经具备真实运行、知识检索、产物生成和确认写入能力的 Agent 工作台收口为可发布候选：补齐失败 Run 重试，证明 Agent 与 MCP 复用同一领域能力，完成产品门禁、国际化、自动化测试、真实 UI 验收和 Release 入口策略，并让需求、设计、代码、测试和工程进度保持一致。

## 2. 当前可信基线

- [x] `v19-agent-message-contract`、Run/Message/Approval/Artifact 持久化与恢复已落地。
- [x] Agent Composer 已复用共享输入组件，支持 `@repo`、多来源仓库、附件、链接、联网、模型与草稿冻结。
- [x] 仓库目录覆盖 `repos + Weekly + Trending + Discovery`，Star 与知识库仅作为筛选维度，80 条仅为展示窗口。
- [x] Knowledge Tool、Repository Read Capability 与 External Search Adapter 已落地。
- [x] GitHub Weekly Report、Repo Insight、Repo Alternatives 三个只读 Artifact Agent 已启用。
- [x] Untagged Tidy 已完成 dry-run、明确审批、共享 Tag Capability、apply 与 read-back 写入闭环。
- [x] Run 取消、等待确认恢复、进程中断收口、历史列表与历史快照查看已落地。
- [x] Pro Gate、Agent 用量归因、私有仓库外部搜索边界和现有 Agent 国际化已落地。

## 3. 本轮实施任务

### A. 失败 Run 重试

- [x] 为 `AgentRuntime` 增加失败 Run 重试契约，和等待审批恢复契约分离。
- [x] 从持久化消息恢复同一 Run 的上下文、预算、usage、sequence 与 Artifact 计数。
- [x] 重试时清理旧错误和终态时间，同时保持原 Run ID 与完整审计链。
- [x] 已执行写工具不得因重试再次执行；上下文不可恢复或存在未决写操作时 fail closed。
- [x] Agent Workspace 在失败错误行提供明确重试动作，并防止重复点击并发重试。
- [x] 补齐 Runtime、Session、Repository、ViewModel 与 UI 状态投影测试。
- [x] 首次加载历史时把上次进程遗留的 `planning` / `running` 原子收口为可重试失败态；等待审批与既有终态不受影响。
- [x] Artifact Agent 在迭代耗尽前进入 Definition 驱动的最终提交回合，只暴露 `completesRun` 工具并强制结构化调用，不按 Agent ID 写特例。

> 验证：2026-08-14 完成重试、进程中断恢复与 Artifact 收敛测试；同一 Run 续跑、写工具不重放、未决审批拒绝、终态字段原子清理、遗留执行态收口和最后一轮 completion-only 均有自动化覆盖。

### B. Agent / MCP 统一能力层

- [x] 核对仓库读取、metadata、Tag、Note、Status 与 Knowledge Search 的共享 executor。
- [x] 消除 Agent 当前使用领域中的重复业务实现；不重构与 Agent 无关的 MCP Tool。
- [x] 增加 Agent / MCP 契约测试，证明两端复用同一能力、权限、dry-run 和 read-back 语义。
- [x] 保证内置 Agent 不依赖 MCP listener、端口或 API Key。

> 验证：2026-08-14 将 Agent / MCP 标签能力统一到同一装配点，补回 Agent 写后语义索引刷新；MCP 写入仓库解析改用 Repository Read Capability。Note / Status 继续由共享 Metadata Capability 执行，当前内置 Agent 不臆造未使用 adapter；24 个相关测试套件通过。

### C. 产品化与 Release Gate

- [x] 补齐失败重试、历史恢复、空态、错误态和取消状态的一致 UI。
- [x] 新增文案同步 18 个 locale，并执行 String Catalog 格式与完整性检查。
- [x] 复核 Pro、AI Provider、用量、隐私与 App Store / Direct 渠道边界。
- [x] 自动化与真实 UI 验收通过后解除 `DebugFlags.agentToolbarEntry`，并保留既有权限门禁。

> 验证：2026-08-14 已移除 Agent 工具栏 Debug 开关，Release 构建通过；真实 UI 证明正式入口可见、免费用户进入 AI Chat Pro 付费墙、Pro 用户未配置模型进入配置门禁。修复门禁失败仍误记新手引导完成，以及 Agent 误用 RAG 模型提示文案；Agent 新增文案 18 个 locale 完整、非空且均为 translated。

### D. Run Surface 过程 / 结果双层呈现

- [x] 使用 `toolCallID` 把 call/result 投影成单个工具执行节点，不改消息事实和数据库。
- [x] 相邻同类工具按稳定 `presentationKey` 聚合，Approval、失败与用户可见进度形成边界。
- [x] 运行与审批态默认展开过程，完成、取消和历史完成态默认折叠，并尊重用户手动选择。
- [x] 最终回答与 Markdown Artifact 在中栏直接渲染，`.log` 与原始审计不进入主结果区。
- [x] 普通 UI 不展示模型原始 reasoning、input/output 或技术 log；来源和 Knowledge Audit 保留二级核验入口，完整工具事实继续持久化。
- [x] 用户主动上滚后流式更新不再抢回滚动位置，切换 Run 时重置折叠偏好。
- [x] 当前 Run 展示问题与 Composer 草稿分离，发送、完成刷新和打开历史都不会把已发送问题重新塞回输入框。
- [x] Run Header 固定为紧凑高度，标题区不再与正文争抢剩余高度，用户问题和执行过程直接进入首屏。
- [x] 移除 Header 开发者副标题、大卡片嵌套与内部英文工具名；过程改为连续任务叙事，Artifact 改为连续 Markdown 正文。
- [x] 增加真实 `NSWindow + NSHostingView` 像素渲染测试，禁止尺寸正确但内容全白的截图假通过。
- [x] 补齐 call/result 合并、Activity Group、顺序、结果分层、Markdown/log 边界和默认折叠测试。

> 验证：2026-08-14 `AgentTimelineProjectionTests` 与 `AgentWorkspaceViewModelTests` 最新 36 项通过；`NSHostingView` 真实像素渲染确认浅灰用户消息、单一 Agent 身份、纵向任务进展、自然语言活动与连续 Markdown 正文进入同一阅读流。投影只消费现有 Message / Approval / Artifact，未修改消息协议或数据库 schema。

### E. 文档、测试与工程进度

- [x] 更新权威 Agent 设计中的当前实现状态、阶段状态与验收结论。
- [x] 同步 `docs/功能实现总览.md` checkbox、`> 实现：`、进度仪表盘与变更日志。
- [x] Agent、Capability、MCP 定向测试全部通过。
- [x] StarcatTests 全量测试与 Debug build 通过。
- [x] 正式 Agent 入口、免费 Pro 付费墙与 Pro 无模型配置门禁完成真实 UI 验收。
- [x] 真实 v19 数据证明 Provider 完成 Run、消息 / Artifact 持久化、Knowledge Search citation 与私有上下文外部搜索阻断。
- [x] 使用最终代码完成一次真实 Provider Run 与完整 Run Surface / 历史 / Artifact 导出视觉验收。
- [x] 完成一次成功 External Search / GitHub 联网 Run；多批成功搜索证据共同支撑候选准入与最终 Artifact。
- [x] App Store / Direct 两个 Release scheme 最终代码均完成 `CODE_SIGNING_ALLOWED=NO` 构建。
- [ ] 在发版流程生成的 App Store / Direct 真实产物上完成双渠道人工验收；本专项未获授权执行打包、签名、公证或上传脚本。
- [x] 完成至少三轮完整审查，每轮保存独立报告、修复问题并提交。
- [x] 生成 `Agent产品化收口需求完成结果报告.md`，并如实保留未关闭的外部人工门禁。

> 当前证据：2026-08-14 已完成 Agent / Capability / MCP 定向套件、最新 2,287 项全量测试（0 failed）、36 项 Run Surface 定向测试、Debug build、App Store / Direct Release build、Agent String Catalog 18 locale 完整性检查与十一轮审查。历史真实 Run `B5B9A14A-E616-4EE4-AC7A-536D8EF42F4F` 在 31 秒内完成 External Search、历史回看及 2,779 字符 Artifact 导出；最新连续任务叙事界面由同一生产视图在真实 `NSWindow + NSHostingView` 中通过像素验收。Debug 数据容器的真实历史页面复验受既有对话模型配置门禁限制，真实分发产物双渠道验收仍等待发版授权。

## 4. 明确非目标

- [x] Recall Search 继续归属知识库 RAG，不重复建设 Agent。
- [x] Overlap Scan 与 Release Watcher 保持后续候选，不属于本轮 P0～P4 收口。
- [x] P5 外部 CLI Runtime 未满足进入条件，本轮不实施。
- [x] 不开放 Shell、文件编辑、浏览器自动化、subagent 或后台无人值守写入。
- [x] 不迁移与当前 Agent 无重叠的 MCP Tool，不借专项做相邻重构。

## 5. 结束条件

- [ ] 所有本轮实施任务和验收项均有当前证据并正确回填。
- [x] 代码、需求、设计、专项 checklist 与功能实现总览一致。
- [x] 单元测试、全量测试、构建和可执行的真实 UI 验收通过。
- [x] 连续终审不再发现新的仓库内遗留问题。
- [x] 所有已完成轮次的审查报告和最终结果报告已保存。
- [x] 全部改动按独立功能使用中文 commit 提交，且未 push。
