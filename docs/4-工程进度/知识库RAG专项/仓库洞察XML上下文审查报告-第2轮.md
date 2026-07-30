# 仓库洞察 XML 上下文审查报告（第 2 轮）

> 日期：2026-07-30  
> 范围：功能完整性、RAG 全链路、知识库 UI 与可解释性  
> 结论：发现的 1 个 P1 已修复并通过定向复验

## 1. 审查结论

知识库详情已经覆盖特殊项顺序、独立 `0 / 1` 统计、只读查看、复制、下载、删除和重新生成。旧 Artifact 在生成期间保持可见，不使用全页加载态；所有新增 plain Button、Sheet、颜色和 en / zh-Hans 文案符合现有设计约束。

RAG 的 Planner 后目标选择、cache-only 加载、独立 Prompt section、XML 感知投影、总窗口预算、证据门禁、citation、Plan / Timeline / Context / Evidence / Debug 和历史 hash 回放已贯通。仓库 AI 与 RAG 消费同一个 XML。

## 2. 问题

### P1-1 主动生成取消没有抵达 Coordinator 内部任务

- 位置：`KnowledgeRAGBrowserViewModel.cancelRepositoryInsightsGeneration()`、`RepositoryInsightsContextCoordinator.prepare(...)`
- 现象：知识库切仓、移出知识库或关窗只取消 ViewModel 的外层 Task。Coordinator 为 single-flight 创建的非结构化 Task 仍继续执行 `.forceRegenerate`，并可能继续联网和写盘。
- 已有保护：generation UUID + repo id 能拒绝旧结果上屏。
- 剩余风险：用户已停止或离开页面后仍产生网络请求和 Artifact 写入；这不符合“取消主动任务”，也会浪费 GitHub / Discovery 配额。
- 修复要求：只为知识库主动 `.forceRegenerate` 暴露 repo + scope 定向取消；取消内部 Task，并在 Provider 返回后、Storage 写入前再次检查取消。不得用全局取消影响页面 / AI 的 `.refreshIfNeeded` 或 RAG `.cacheOnly`。

## 3. 已确认无缺口

- 洞察 XML citation 使用 `chunkID = nil`，不会显示普通“分片已删除”。
- XML 预算在写入 Prompt 前完成合法投影；空间不足时整份移除。
- 洞察 XML 可作为唯一真实仓库级证据；其它证据存在时洞察降级不阻断回答。
- 历史仅在 repo id、source hash、XML hash 全部匹配时回放，不冒用新 XML。
- 专用 Debug stage 不保存 XML 正文，最终 Prompt 的本地 Debug 隐私提示已更新。
- Repository Insights XML sheet 是只读，RepoContext 编辑能力没有被错误复用。

## 4. 修复与复验

- [x] 增加 repo + scope + mode 定向取消入口，仅取消 `.forceRegenerate`。
- [x] Provider 返回后、写盘前拒绝已取消任务。
- [x] 切仓 / 移库 / 关窗通过既有生命周期调用内部取消。
- [x] 新增迟到 Provider 结果不写盘测试。
- [x] Coordinator、RepoContext Storage 与 Knowledge RAG Core 定向测试通过。

修复提交：`f48aa80 fix(rag): 真正取消洞察 XML 主动生成`。
