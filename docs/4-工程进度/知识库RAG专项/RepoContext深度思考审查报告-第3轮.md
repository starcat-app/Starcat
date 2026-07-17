# RepoContext 深度思考审查报告（第 3 轮）

> 日期：2026-07-17
> 范围：方案、代码、测试、i18n、专项进度、Checklist、提交粒度与最终工程门禁
> 结论：静态一致性检查发现 1 个 P1、1 个 P2；本报告先落档，修复后再执行完整工程门禁并回填。

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
- `pages/appstore/index.html` 同样是并行改动，本专项未纳入任何提交。

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

> 待 P1/P2 修复、完整工程门禁和结果报告完成后回填 commit、测试矩阵与最终结论。
