# Agent 产品化收口专项 Checklist

> 状态：进行中
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
- [x] Run 取消、等待确认恢复、历史列表与历史快照查看已落地。
- [x] Pro Gate、Agent 用量归因、私有仓库外部搜索边界和现有 Agent 国际化已落地。

## 3. 本轮实施任务

### A. 失败 Run 重试

- [x] 为 `AgentRuntime` 增加失败 Run 重试契约，和等待审批恢复契约分离。
- [x] 从持久化消息恢复同一 Run 的上下文、预算、usage、sequence 与 Artifact 计数。
- [x] 重试时清理旧错误和终态时间，同时保持原 Run ID 与完整审计链。
- [x] 已执行写工具不得因重试再次执行；上下文不可恢复或存在未决写操作时 fail closed。
- [x] Agent Workspace 在失败错误行提供明确重试动作，并防止重复点击并发重试。
- [x] 补齐 Runtime、Session、Repository、ViewModel 与 UI 状态投影测试。

> 验证：2026-08-14 完成 4 个重试核心测试套件及 24 个 Agent / Capability / MCP 相关测试套件；同一 Run 续跑、写工具不重放、未决审批拒绝、终态字段原子清理均有自动化覆盖。

### B. Agent / MCP 统一能力层

- [ ] 核对仓库读取、metadata、Tag、Note、Status 与 Knowledge Search 的共享 executor。
- [ ] 消除 Agent 当前使用领域中的重复业务实现；不重构与 Agent 无关的 MCP Tool。
- [ ] 增加 Agent / MCP 契约测试，证明两端复用同一能力、权限、dry-run 和 read-back 语义。
- [ ] 保证内置 Agent 不依赖 MCP listener、端口或 API Key。

### C. 产品化与 Release Gate

- [ ] 补齐失败重试、历史恢复、空态、错误态和取消状态的一致 UI。
- [ ] 新增文案同步 18 个 locale，并执行 String Catalog 格式与完整性检查。
- [ ] 复核 Pro、AI Provider、用量、隐私与 App Store / Direct 渠道边界。
- [ ] 自动化与真实 UI 验收通过后解除 `DebugFlags.agentToolbarEntry`，并保留既有权限门禁。

### D. 文档、测试与工程进度

- [ ] 更新权威 Agent 设计中的当前实现状态、阶段状态与验收结论。
- [ ] 同步 `docs/功能实现总览.md` checkbox、`> 实现：`、进度仪表盘与变更日志。
- [ ] Agent、Capability、MCP 定向测试全部通过。
- [ ] StarcatTests 全量测试与 Debug build 通过。
- [ ] 完成真实 UI、真实 Provider、External Search、GitHub、私有仓库与双渠道人工验收；无法自动观察的证据如实记录。
- [ ] 完成至少三轮完整审查，每轮保存独立报告、修复问题并提交。
- [ ] 生成 `Agent产品化收口需求完成结果报告.md`。

## 4. 明确非目标

- [x] Recall Search 继续归属知识库 RAG，不重复建设 Agent。
- [x] Overlap Scan 与 Release Watcher 保持后续候选，不属于本轮 P0～P4 收口。
- [x] P5 外部 CLI Runtime 未满足进入条件，本轮不实施。
- [x] 不开放 Shell、文件编辑、浏览器自动化、subagent 或后台无人值守写入。
- [x] 不迁移与当前 Agent 无重叠的 MCP Tool，不借专项做相邻重构。

## 5. 结束条件

- [ ] 所有本轮实施任务和验收项均有当前证据并正确回填。
- [ ] 代码、需求、设计、专项 checklist 与功能实现总览一致。
- [ ] 单元测试、全量测试、构建和可执行的真实 UI 验收通过。
- [ ] 连续终审不再发现遗留问题。
- [ ] 所有审查报告和最终结果报告已保存。
- [ ] 全部改动按独立功能使用中文 commit 提交，且未 push。
