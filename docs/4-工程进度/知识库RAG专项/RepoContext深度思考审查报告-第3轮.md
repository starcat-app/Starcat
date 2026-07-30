# RepoContext 深度思考审查报告（第 3 轮）

> 日期：2026-07-17
> 范围：方案、代码、测试、i18n、专项进度、Checklist、提交粒度与最终工程门禁
> 结论：发现的 1 个 P1、1 个 P2 及全量测试暴露的 2 类断言/时序问题均已修复，最终工程门禁通过。

## 1. 审查方法

- 逐项对照 `RepoContext深度思考实施方案.md`、正式 RAG 详细设计、开发前问题清单、专项进度与 Checklist。
- 检查从 `XmlOutputBuilder` 到 Service、XML projector、Prompt、citation、execution trace 和历史回放的 schema 契约。
- 复核本专项提交序列，确认方案、清单、功能、测试和每轮审查均使用独立中文 commit，且没有 push。
- 只读检查 `docs/功能实现总览.md` 当前差异，确认其中为并行 Direct Pro 改动，本专项没有写入。
- 规划最终门禁：`xcodegen generate`、i18n/静态检查、RAG 定向测试、全量测试、`Starcat` 与 `StarcatDirect` Debug build。

## 2. 已确认正确

- 方案中的五项补充均已进入正式设计、产品决策、专项进度和实现。
- 新增 Swift 文件已在工程中可编译；模型、Prompt、预算、Provider、Composer、时间线、Debug、Plan、citation 与 Evidence 均有对应实现。
- RepoContext 相关变更从方案到两轮审查修复均为独立中文 commit；未执行 push、打包、发布或上传。
- `docs/功能实现总览.md` 当前存在其他任务的 Direct Pro 并行改动，本专项未暂存、未提交；根据仓库铁律只起草待确认同步内容。
- `supports/starcat-site/appstore/index.html` 同样是并行改动，本专项未纳入任何提交。

## 3. 发现的问题

### P1：未触发投影时，XML projector 没有验证 RepoContext 根节点契约

`RAGRepoContextXMLProjector.project` 在 `originalTokens <= tokenBudget` 时直接返回原 XML，只有需要投影时才解析并校验根节点为 `<repository>`。Service 当前也只检查“存在任意根节点”，因此 `<repoContext/>` 或其它合法 XML 在不需要裁剪时会被当成成功证据；测试 Provider 恰好使用了错误的 `<repoContext>` 根节点，掩盖了实际 `XmlOutputBuilder` 输出 `<repository>` 的正式契约。

修复要求：projector 无论是否投影都先解析并验证 `<repository>`；Service 成功入口执行同一根节点校验；测试 fixture 改用真实 schema，并把错误根节点加入降级测试。

### P2：Checklist 的测试与前两轮审查状态没有随已完成证据回填

Service 降级/取消、草稿、历史 citation round-trip、Inspector read model、第一轮和第二轮审查均已有代码、测试和报告，但对应 checkbox 仍为未完成。继续保留会让专项进度与真实提交证据冲突。

修复要求：在最终门禁完成后按可复现证据回填已完成项；仍无法自动观察的人工 UI 项单独标明，不把代码审查冒充人工操作验收。

## 4. `docs/功能实现总览.md` 待确认草案

本轮不写该文件。建议 dong4j 后续明确“可以写总览”后，在 RAG 对应章节登记：

```text
- [x] **单项目 RepoContext 深度思考** — Composer 单项目授权后复用 RepoAIContextProvider，将独立 XML 上下文接入计划、时间线、Prompt、引用、Evidence、Debug 与历史审计 — `Starcat/Features/RAG` / `docs/4-工程进度/知识库RAG专项/RepoContext深度思考实施方案.md` — 2026-07-17
> 实现：使用独立 `{repoContextSection}` 与仓库级 citation；XML 不受分片 evidence budget 限制但服从模型总窗口，失败可降级且不复制进普通消息或索引。
```

建议变更日志草案：

```text
- 2026-07-17 HH:MM: RAG 新增单项目 RepoContext 深度思考与完整可解释链路
```

## 5. 最终门禁与修复回填

- P1 修复：`455c9945 RAG：统一校验 RepoContext XML 根节点契约`。projector 和 Service 无论是否投影都验证 `<repository>`，测试 fixture 与正式 Packer schema 对齐。
- P2 修复：`0c2a42ff 文档：回填 RepoContext 三轮审查与自动化门禁`。已按实际报告、测试和构建证据更新 Checklist 与专项进度。
- 全量测试发现缺少 `{repoContextSection}` 的旧断言仍假定自定义 Generator 可保留，已用 `e9177d65 测试：同步 RepoContext 提示词持久化契约` 对齐本需求“不保留旧模板兼容”的明确决策。
- 全量测试同时稳定复现 3 个 Home 列表测试在 sidebar 切换后又并发手动 reload，后创建的排序任务会取消测试查询；`3d2e8a1f 测试：稳定知识库列表切换异步门禁` 改为等待 ViewModel 自己派发的分页重载。该修复不改变生产代码。
- 覆盖补强：`96fad56d 测试：补齐深度思考门禁与调试阶段覆盖`，新增 0/1/2 项目门禁和 RepoContext request/response/projection Debug stage 脱敏断言。

最终验证矩阵：

- `xcodegen generate`：通过，生成后 `Starcat.xcodeproj` 无差异。
- `jq empty Starcat/Resources/Localizable.xcstrings`、`git diff --check`、禁用本地化 API 扫描：通过。
- `Starcat build-for-testing`：通过。
- `KnowledgeRAGCoreTests`、`RAGChunkBuilderTests`、`RAGChunkRepositoryTests`、`RAGConversationHistoryWindowTests`、`RAGLocalizationTests`：通过。
- 全量 `Starcat test`：修复断言/时序后连续两次功能性执行通过。其中一次额外重跑在测试尚未启动前遭 test host signal kill，未生成崩溃报告；再次执行 35.563 秒通过，判定为 testmanager 基础设施瞬态而非测试失败。
- `Starcat` Debug build：通过。
- `StarcatDirect` Debug build：通过。
- warning：没有新增产品代码 warning；`KnowledgeRAGCoreTests` 第 924～930 行仍有此前已有的 MainActor 测试 warning，已在前两轮报告记录。

最终结论：本轮所有发现均已清零，方案、代码、测试、i18n、专项进度和 Checklist 已一致，可以进行只读清洁复审。
