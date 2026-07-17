# RepoContext 深度思考审查报告（第 2 轮）

> 日期：2026-07-17
> 范围：Composer 顺序与门禁、按会话草稿、执行时间线、Plan、Evidence、引用定位、历史 XML、Debug Trace 与无障碍
> 结论：发现的 1 个 P1、1 个 P2 均已修复，UI、草稿持久化与可观测性审查通过。

## 1. 审查方法

- 对照实施方案 §2、§6、§7 和 Checklist §4～§6、§10 逐项核对 SwiftUI 与 ViewModel 实现。
- 追踪 Composer 控件顺序、`RAGComposerDraftStore` 保存/恢复、发送快照和唯一项目门禁。
- 追踪 Provider 成功、总窗口投影、执行事件 reducer、自动折叠与历史 execution trace。
- 核对 Plan、独立 RepoContext 证据区、citation marker 定位、XML 预览/复制和历史 repo + commit + hash 校验。
- 核对 Debug stage 的 UI 标题、payload、导出/历史编解码与隐私说明。

## 2. 已确认正确

- Composer 顺序为附件 → 联网搜索 → 深度思考 → 发送；深度思考是 `brain.head.profile` 图标，没有常驻文本。
- 深度思考只有 `selectedRepoContexts.count == 1` 时可开启；附件数量不参与门禁，项目变为 0 或多项目时立即关闭。
- 深度思考和联网开关都进入同一 `RAGComposerDraftSnapshot`，按会话保存在 App 级内存 store；发送请求使用冻结快照。
- 图标按钮遵循 `.buttonStyle(.plain)` + `.focusEffectDisabled()`，并提供 tooltip 与 accessibility label。
- Plan 展示目标、原因、配置预算、outcome、commit、cache、原始/发送 token 与投影状态。
- RepoContext 使用独立 Evidence 区与 XML 五行预览、全文 popover、复制反馈；不伪装成普通 `rag_chunks` 分片。
- `[S<n>]` RepoContext marker 能定位独立证据区；citation 没有 `chunkID` 时不会错误显示“分片缺失”。
- 历史 XML 只有 repo、commit、原文 SHA-256 同时匹配时才按当轮 `sentTokens` 重建；否则只显示不可回放提示。
- Debug Trace 包含 request/response/projection 三个独立 stage，专项 payload 不复制 XML；最终 Prompt stage 的完整 XML 暴露边界已有明确提示。

## 3. 发现的问题

### P1：Provider 成功会过早完成时间线，投影没有真实的用户可见子状态

Provider 生成 XML 后立即发出 `repoContextCompleted`，此时 `sentTokens` 仍为 0，时间线会先显示“完成”并自动折叠。总窗口投影发生在远程上下文之后，只有 Debug stage 和第二次 completed 更新，没有“正在投影”的用户可见动作；若投影失败但其它附件/分片仍可回答，RepoContext 步骤还可能被后续步骤隐式完成，缺少准确的 degraded 结果。

修复要求：区分“XML 已准备”和“开始总窗口投影”，成功时只在投影结束后完成；投影失败必须发出 degraded snapshot，不能留下 running/伪 success。时间线详情应显示真实的“按模型总窗口投影”子状态，并增加事件转换测试。

### P2：降级快照会被右侧误当成独立 XML 证据展示

Evidence 区目前只判断 `displayedRepoContextSnapshot != nil`。Provider 禁用、失败或 XML 非法时也会生成 degraded snapshot，于是右侧仍展示 commit/hash/token/cache 字段和“历史项目代码上下文不可用”，看起来像曾有一份成功 XML，只是历史丢失。

修复要求：独立 RepoContext Evidence 区只展示 `outcome == .success` 的快照；失败原因继续由时间线和 Plan 呈现。增加 Inspector read model 或等价纯逻辑测试，锁定 degraded 不展示、success 展示。

## 4. 本轮门禁记录

- Composer 顺序、唯一项目门禁、草稿保存/恢复：代码与既有定向测试一致。
- Plan、citation、历史 hash 校验、Debug stage：实现边界与方案一致。
- SwiftUI 规范：未发现 `.tertiary`、缺失 focus ring 禁用或折叠行仅 chevron 可点问题。
- 当前工作区的 `docs/功能实现总览.md`、`pages/appstore/index.html` 仍为并行改动，本轮不暂存、不提交。

## 5. 修复回填

- 修复提交：`88a167b6 RAG：修正项目上下文投影时间线与证据状态`。
- P1：新增 `repoContextPrepared` 与 `repoContextProjectionStarted` 事件；Provider 成功只标记 XML 已准备，最终投影成功或失败后才完成步骤。失败统一写入 `total_context_projection_unavailable` degraded snapshot。
- P2：新增统一 Evidence 可见性判断，只有 `outcome == .success` 才展示独立 XML 证据；degraded 仍可在 Plan、时间线核对。
- 定向测试锁定事件顺序 `prepared → projecting → completed`，并覆盖 success/degraded/nil 三种 Evidence 可见性。
- 修复后验证：`jq empty Starcat/Resources/Localizable.xcstrings`、`git diff --check` 与 `KnowledgeRAGCoreTests` 均通过；仅保留该 Suite 既有 MainActor warning。
- 最终结论：本轮问题已清零，可以进入第 3 轮测试、文档、工程进度和 checklist 一致性审查。
