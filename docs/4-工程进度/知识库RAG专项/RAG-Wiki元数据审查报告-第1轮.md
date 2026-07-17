# RAG Wiki 元数据审查报告（第 1 轮）

> 审查日期：2026-07-17  
> 审查范围：Wiki 数据流、缓存生命周期、后台补齐、私有仓库边界、账号 / 数据库切换屏障  
> 审查结论：发现 1 个 P1、1 个 P2，修复后进入下一轮审查

## 已核对

- 前台详情、搜索、Repo AI、Companion 均通过 `WikiContextService.cacheFirstLinks` 读取，不再直接请求 `WikiAPI`。
- fresh 只读缓存，stale / miss 进入同一有界队列；相同仓库在 pending / in-flight 两个阶段均去重。
- 私有仓库在消费方、后台协调器与统一服务三层阻断，不向第三方 Wiki 服务发送仓库 identity。
- 知识库启动扫描与新增入库通知均进入同一队列；账号 / 数据库切换前会取消扫描和网络任务并推进 generation。
- Wiki 缓存写入与清空只触发受影响仓库的 Metadata 重建，索引构建过程中不发起 Wiki 网络请求。
- Wiki、缓存、Metadata、Prompt/Retriever、Companion 六组定向测试通过。

## 发现项

### P1：缓存清空监听忽略取消信号

`KnowledgeRAGIndexBuilder` 处理 `.wikiCacheDidReset` 时使用 `try? Task.checkCancellation()`。该写法会吞掉 `CancellationError`，导致 builder 停止或切库后仍可能继续遍历旧 key，并访问已经切换的 repository。

修复要求：在循环入口显式检测取消并立即退出，保持与 builder 其他生命周期监听一致。

### P2：缓存变更通知契约缺少单元测试

当前实现依赖 `.wikiCacheDidChange` 携带 `owner` / `repo`，以及 `.wikiCacheDidReset` 携带清空前的 `repositoryKeys` 来执行精确 Metadata 重建，但 `DiskWikiCacheTests` 尚未锁定这个通知 payload。后续字段名或发送时机变化可能静默破坏增量重建。

修复要求：分别为 `save` 与 `deleteEverything` 增加通知 payload 测试，并验证清空事件保留受影响仓库 identity。

## 本轮后续动作

1. 修正 reset 监听的取消处理并提交。
2. 补充缓存通知契约测试并提交。
3. 回填本报告的修复状态后，开始第 2 轮 UI 与上下文语义审查。
