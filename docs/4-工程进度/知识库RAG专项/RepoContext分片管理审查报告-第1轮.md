# RepoContext 分片管理审查报告（第 1 轮）

> 日期：2026-07-17
> 范围：架构、数据真源、生成状态、取消传播、缓存与隐私边界
> 结论：发现 1 个 P1、1 个 P2，先记录报告，待后续独立提交修复后回填。

## 1. 审查方法

- 对照 `RepoContext分片管理实施方案.md`、Checklist、详细设计与已提交代码逐项检查。
- 追踪 `AppDependencies → KnowledgeRAGBrowserViewModel → RepoAIContextProvider → RepoContextStorage`。
- 检查普通分片 SQL、分页、embedding、统计、CloudKit、消息和 External Search 是否接触 XML。
- 检查主动生成在点击停止、repo 切换、筛选导致选择变化、移出知识库和窗口关闭时的 Task 生命周期。
- 复核 `SharedSnapshotService` 临时文件清理测试和 Provider 的正式 ZIP / XML 缓存行为。
- 执行 RepoContext 定向测试、`jq empty` 与 `git diff --check`。

## 2. 已确认正确

- RepoContext 只在知识库浏览器展示层投影，不新增 `RAGChunkSource`，不写 `rag_chunks`，普通分页与索引统计保持原口径。
- 文件读取、编辑和删除均走 `RepoContextStorage`；编辑前要求 `<repository>` 根节点，写入失败不会覆盖原文件。
- 主动生成复用 `AppDependencies.repoAIContextProvider`，没有复制分支解析、ZIP 下载、缓存或 packer 实现。
- UI 只展示 resolving、downloading、packing 三个 provider 真实阶段，没有伪造百分比。
- 显式停止会取消 Task 并调用现有窄清理；`SharedSnapshotServiceTests` 已锁定只删除 `.tmp`、不删除正式 ZIP。
- 当前 repo 切换、移出知识库和窗口关闭会取消生成；成功结果使用 repo id 与 UUID 校验后才回写。
- XML 不进入普通消息、CloudKit、embedding 或 External Search；知识库管理入口没有新增出站路径。
- RepoContext 定向 Suite 6 项通过；本轮无 schema 变更。

## 3. 发现的问题

### P1：筛选或搜索自动替换选中仓库时没有取消旧生成任务

`loadRepositories` 在当前选中仓库不再属于新候选页时会直接把 `selectedRepoID` 改为首个候选，没有经过 `selectRepository`。旧生成回调虽会因 repo id 不匹配而拒绝正文回写，但下载/打包仍继续；完成 guard 提前返回后也不会清理 ViewModel 中的 task/repo/state，新的仓库详情可能持续显示旧任务的进行态。

修复要求：所有程序化选择变化也必须先取消旧 RepoContext 生成、清理 `.tmp` 并清空旧 XML；增加纯状态/身份回归测试，锁定旧 generation id 或旧 repo id 均不得接受结果。

### P2：主动生成的过期结果防护只有实现，没有专项可执行测试

现有测试覆盖进度映射和通用 `RAGLatestRequestGate`，但没有直接表达 RepoContext 生成必须同时匹配 generation id 与 repo id。后续改动可能只保留其中一个条件，使“取消后迟到结果”或“切仓后迟到结果”重新污染第二项。

修复要求：抽取最小纯身份值对象或等价可测边界，并覆盖当前请求、generation id 过期、repo 过期三种断言；不为测试暴露整个私有 ViewModel。

## 4. 本轮门禁记录

- `RepoContextStorageTests`：6 项通过。
- `Localizable.xcstrings` JSON：通过。
- `git diff --check`：通过。
- `Starcat` 编译：随定向测试构建通过。
- 工作树存在另一项并行开发的 4 个文件，本需求未暂存、未修改。

## 5. 修复回填

待修复提交完成后回填。
