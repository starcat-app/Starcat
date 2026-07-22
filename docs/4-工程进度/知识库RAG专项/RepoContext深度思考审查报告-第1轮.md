# RepoContext 深度思考审查报告（第 1 轮）

> 日期：2026-07-17
> 范围：架构、预算、XML 合法性、证据门禁、取消语义、数据库与隐私边界
> 结论：发现的 1 个 P1、1 个 P2 均已修复，架构与执行边界审查通过。

## 1. 审查方法

- 对照 `RepoContext深度思考实施方案.md`、`RepoContext深度思考Checklist.md` 与本需求中文提交逐项检查。
- 追踪 `AppDependencies → KnowledgeRAGService → RepoAIContextProvider → PromptBuilder → citation/execution trace`。
- 检查 `RAGContextBudget`、`RAGRepoContextXMLProjector`、Generator 证据门禁与历史 hash 校验。
- 搜索 RAG schema、conversation store、CloudKit 与 External Search，确认 XML 是否进入不允许的持久化/出站路径。
- 执行 `git diff --check`、`jq empty Localizable.xcstrings`、`Starcat` Debug build 与 `KnowledgeRAGCoreTests`。

## 2. 已确认正确

- 生产依赖复用同一个 `RepoAIContextProvider`，没有第二套下载、缓存或 packer 实现。
- 执行顺序固定为本地检索 → RepoContext → 联网 → Generator；目标由本地唯一显式项目生成，Planner 无权扩大。
- `{repoContextSection}` 与 `{evidenceSection}` 独立；RepoContext 不读取 chunk evidence budget/topK/cap，但仍通过统一总窗口扣减。
- XML 投影按完整节点裁剪，投影结果会重新用 `XMLDocument` 解析；PromptBuilder 不会字符级截断后继续发送非法 XML。
- RepoContext 可单独通过证据门禁；投影失败且没有其它真实证据时会回到无证据路径。
- 会话只保存 `RAGRepoContextSnapshot` 和 citation；XML 不写 `rag_chunks`、普通消息正文或 CloudKit。
- 历史 XML 必须同时匹配 repo、commit 与原文 SHA-256，再按当轮 sentTokens 重建投影。
- RepoContext 专用 Debug stage 只存摘要；完整 XML 仅随既有最终 Prompt stage 写入本地 Debug 文件，UI 已明确隐私和清理边界。
- External Search 不接收 XML；私有仓库 identity 仍受原有 `externalSearchAllowPrivateRepos` 门禁。
- 当前工作区另有 `docs/功能实现总览.md`、`supports/starcat-site/appstore/index.html` 的并行改动，本需求未暂存、未提交这些文件。

## 3. 发现的问题

### P1：Provider 返回空或损坏 XML 时，执行步骤会先错误标记成功

`runRepoContextPhase` 当前只根据 Provider outcome 判断 `.success`，没有在生成 success snapshot 前验证 XML 非空且可解析。损坏 XML 会在 PromptBuilder 投影时被丢弃，但时间线已经收到一次 success completion；如果同时存在附件/分片，整轮继续生成后仍会留下“项目上下文已就绪”的错误审计结果。

修复要求：在 RepoContext phase 入口完成非空与 XML 解析校验；失败转换为 degraded snapshot/debug outcome，不能发出成功 document。增加空 XML、非法 XML 降级测试。

### P2：取消、降级与审计 round-trip 缺少 RepoContext 专项回归测试

现有测试覆盖唯一项目、多附件、多项目拒绝、独立预算、占位符、合法投影和 citation，但没有直接锁定：

- Provider `.degraded` 时其它附件证据继续生成；
- Provider 抛 `CancellationError` 时整轮取消且执行临时清理；
- `RAGExecutionStep.repoContextSnapshot` 与 `RAGCitationSource.repoContext` 的 JSON round-trip。

修复要求：补齐上述定向测试，避免未来把取消误吞成 degraded，或历史解码丢失 RepoContext 审计字段。

## 4. 本轮门禁记录

- `Starcat` Debug build：通过。
- `KnowledgeRAGCoreTests`：通过；存在该 Suite 既有的 MainActor 测试 warning，本需求未新增同类 warning。
- `Localizable.xcstrings` JSON：通过。
- `git diff --check`：通过。
- schema 变更：无。

## 5. 修复回填

- 修复提交：`a1174b6c RAG：修复 RepoContext XML 校验与执行边界测试`。
- P1：Service 在发出 success snapshot 前验证 XML 非空、可解析且存在根节点；失败统一转为 `invalid_or_empty_repo_context_xml` degraded，不产生 RepoContext document/citation。
- P2：补齐 Provider degraded、`CancellationError` + cleanup、空/非法 XML，以及 execution trace/citation 历史 round-trip 测试。
- 修复后验证：`xcodebuild -quiet -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/KnowledgeRAGCoreTests test` 通过；仅保留该 Suite 既有 MainActor warning。
- 最终结论：本轮问题已清零，可以进入第 2 轮 UI、草稿持久化与可观测性审查。
