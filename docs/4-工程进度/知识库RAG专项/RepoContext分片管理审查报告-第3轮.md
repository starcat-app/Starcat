# RepoContext 分片管理审查报告（第 3 轮）

> 日期：2026-07-17
> 范围：测试、文档、Checklist、提交历史与工程进度一致性
> 结论：发现 2 个 P2 测试证据缺口，先记录报告，待独立提交修复后回填。

## 1. 审查方法

- 按提交顺序复核方案、存储、展示、下载、生成取消、两轮报告与修复是否均有独立中文 commit。
- 对照实施方案、详细设计 §20、专项进度 §17、Checklist 与代码逐项核验，不以勾选替代证据。
- 只读核对 `docs/功能实现总览.md`，确认本轮未越权改写，并准备最终报告中的待确认同步草案。
- 盘点 RepoContext 专项测试与既有 Provider / SharedSnapshot / 最新请求测试，区分直接证据与复用证据。
- 检查 origin/dev 到当前 HEAD 的文件范围和工作树，确认未混入另一项并行开发文件。

## 2. 已确认正确

- 方案、Checklist、4 个核心小功能、主动生成、正式文档同步、两轮报告和两轮修复均为独立中文提交；没有 push。
- 实现文件范围与需求一致：依赖装配、浏览器控制器、RepoContextStorage、localization、专项测试与专项文档。
- `docs/功能实现总览.md` 未被本需求修改；专项进度明确保留人工 UI 验收未执行状态。
- RepoContext 取消传播与窄清理有复用证据：`KnowledgeRAGCoreTests.cancelledRepoContextStopsTurnAndCleansUp` 和 `SharedSnapshotServiceTests` 的 `.tmp` / 正式 ZIP 边界。
- 过期选择有 RepoContext generation UUID + repo id 专项断言；程序化切仓和非活动提示重置均已补测。
- 存储测试覆盖读取、合法/非法编辑、metadata 派生值、原文件保护和完整项目删除。
- 文档均明确 XML 不进入 `rag_chunks`、embedding、普通消息、CloudKit 或 External Search。

## 3. 发现的问题

### P2：下载测试没有直接证明 RepoContext 缓存未变化

当前 `exportsCurrentDraft` 只验证默认文件名和独立 URL 写入内容，Checklist 却已勾选“下载不修改缓存”和“缓存不变测试”。实现本身没有写存储，但测试没有在真实 fixture 上比较下载前后的 XML 与 metadata，文档证据强于自动化证据。

修复要求：在 RepoContextStorage fixture 已有缓存的前提下导出另一份未保存草稿，随后重读真源并断言 XML、metadata、generationCount 和导出草稿分别保持预期。

### P2：RepoContext `0 / 1` 独立统计仍是 UI 内联表达式，缺少 read model 测试

当前视图直接使用 `repoContextDocument == nil ? "0 / 1" : "1 / 1"`，顺序测试不能证明独立统计不会误用普通 chunk 数量。Checklist 已勾选“独立统计 read model 测试”，证据不完整。

修复要求：抽取最小纯展示函数或读模型，仅由 RepoContext 是否存在计算 `0 / 1` 或 `1 / 1`；测试同时传入不同普通分片数量，锁定统计与 chunk 数量无关。

## 4. 本轮门禁前状态

- RepoContext 定向测试：8 项通过。
- 最终 RAG 组合 Suite、全量测试、双 target build：尚未执行，必须在本轮修复后完成。
- xcstrings JSON、禁用 i18n API、diff check：阶段性通过，最终仍需重跑。
- 工作树存在另一项并行开发的 4 个文件，本需求不会暂存或回退。

## 5. 修复回填

待修复提交完成后回填。
