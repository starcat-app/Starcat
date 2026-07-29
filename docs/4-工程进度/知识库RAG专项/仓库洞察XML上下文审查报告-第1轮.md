# 仓库洞察 XML 上下文审查报告（第 1 轮）

> 日期：2026-07-30  
> 范围：架构、数据一致性、权限边界、并发与性能  
> 结论：发现 1 个 P1，修复前不能结束专项

## 1. 审查结论

结构化快照、XML Renderer、Artifact Storage、页面 / AI / RAG 协调器之间已经形成单一数据链。RAG 只执行 cache-only 准备，多仓库读取有界，Artifact 不写 `rag_chunks`、不向量化，也没有修改已发布 v7 schema。

source hash 不包含生成时间；XML hash 覆盖完整 UTF-8 正文。Storage 读取时同时校验 schema、根节点、repo identity、账号 scope、source hash 与 XML hash。删除抑制、新数据恢复、强制重建和原子目录替换语义一致。

## 2. 问题

### P1-1 删除失败仍从 UI 隐藏 Artifact

- 位置：`RepositoryInsightsContextCoordinator.deleteArtifact(for:)`、`KnowledgeRAGBrowserViewModel.deleteRepositoryInsights()`
- 现象：Coordinator 使用 `try?` 吞掉 Storage 删除错误，调用方没有成功 / 失败结果；ViewModel 随后无条件把 `repositoryInsightsArtifact` 设为 `nil`。
- 风险：磁盘权限、文件损坏或目录删除失败时，知识库界面会让用户误以为洞察 XML 已删除，但文件仍可能保留，后续 RAG 仍可读取并发送给 AI。这违反“可主动删除”的数据控制语义。
- 修复要求：删除契约返回明确结果；只有 Storage 真正完成删除后才清空 UI，失败时保留旧 Artifact 并显示可理解错误；补失败回归测试。

## 3. 已确认无缺口

- 页面与仓库 AI 的正常准备可联网，RAG cache-only 不新增网络请求。
- 私有仓库不会读取普通远端 Metrics；Star History 继续由权限感知 Repository 决定直连或本地范围。
- 相同 repo + scope + mode 使用 single-flight；不同 mode 不强行合并，避免 cache-only 被主动联网任务改变语义。
- Storage actor 承担文件 IO，不在 MainActor 同步读写。
- RAG 最多处理有界目标仓库，并按固定批次并发加载，不扫描整个知识库。
- XML 不包含 Issue / PR 标题、安全公告正文或 Stargazer 身份。

## 4. 修复与复验

- [ ] 删除契约返回成功 / 失败。
- [ ] 删除失败保留 UI Artifact 并显示错误。
- [ ] 补齐成功与失败测试。
- [ ] 重跑 Context / Storage、RepoContext Storage、Knowledge RAG Core 定向测试。
