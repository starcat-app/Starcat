# RAG Wiki 元数据审查报告（第 2 轮）

> 审查日期：2026-07-17  
> 审查范围：Metadata Prompt 语义、预算顺序、citation/hit、知识库分片 UI、详情与搜索 Wiki 展示  
> 审查结论：发现 1 个 P1、2 个 P2，均已修复并通过定向测试 / Debug build

## 已核对

- Retriever 在最终 repo limit 之后批量加载 `metadata:0`，Metadata 命中不会走普通 parent 扩展，也不会生成虚假 citation。
- 完整 Metadata 可用时不会重复输出精简头；缺失或历史排除时使用 compact fallback；`structured_only` 不做全库 Metadata 读取。
- Metadata 在 UI、ViewModel、domain model、repository 四层不可排除或永久删除，仍可查看和编辑 override；普通分片路径不受影响。
- Metadata 行只把固定 provider 行解析成 `http` / `https` 链接，按钮符合 plain button focus 规范；回答正文继续走 Markdown 现有外链路径。
- RepoContext 仍使用独立 `{repoContextSection}` 与独立预算，本需求没有新增 `{metadataSection}`。

## 发现项

### P1：当前预算装配会让高分仓库正文挤掉低分仓库 Metadata

`assembleEvidence` 目前按仓库顺序依次加入“Metadata + 普通分片”。当第一个仓库正文较长时，第二个已进入最终 bundle 的仓库即使 Metadata 很短，也可能因预算不足被整体跳过。这不符合“最终仓库 Metadata 优先于所有普通分片”的语义。

修复要求：改成两阶段装配。第一阶段只按得分顺序放置各仓库完整 Metadata，Metadata 放不下时减少仓库；第二阶段才在已保留仓库之间加入普通证据。增加双仓库预算测试，证明后一个仓库 Metadata 优先于前一个仓库正文。

> 修复状态：已完成。evidence 改为 Metadata / 普通分片两阶段装配，新增双仓库预算测试，提交 `b11a450`。

### P2：详情页与全局搜索在冷缓存刷新完成后不会原地显示 Wiki

两处 UI 已改成 cache-first，但只在首次 task 中读取一次。cache miss 会正确排队并写盘，当前页面却不监听 `.wikiCacheDidChange`，因此链接只能在离开并重新进入后看到；相较旧的阻塞请求形成可见行为回退。

修复要求：详情与搜索详情监听缓存变更事件，只在事件 identity 与当前仓库一致时从缓存重新读取；不重复发网络请求，并防止 repo 切换后旧事件覆盖新状态。

> 修复状态：已完成。详情与搜索同时响应 save / reset 事件，按当前 repo identity 过滤且只读缓存，提交 `8b649b4`。

### P2：Prompt 关键分支缺少直接测试闭环

现有测试覆盖完整 Metadata、fallback、Metadata 自身命中和单仓库预算，但尚未直接锁定 `structured_only` 仍使用 compact metadata，以及多仓库 Metadata-first 预算顺序。Checklist 对该组测试仍未完成。

修复要求：补齐上述测试，并继续断言 Metadata 本身不产生 citation/hit。

> 修复状态：已完成。新增 structured-only compact、双仓库 Metadata-first 测试，并修正完整 / fallback 断言的精确 repo identity，随 `b11a450` 提交。

## 本轮后续动作

1. [x] 两阶段重写 Metadata-first evidence 装配并补测试。
2. [x] 为详情页和全局搜索增加缓存变更后的原地回填。
3. [x] 补齐 structured-only 与多仓库预算测试。
4. [x] `KnowledgeRAGCoreTests`、`RAGChunkRepositoryTests` 与 `Starcat` Debug build 通过。
