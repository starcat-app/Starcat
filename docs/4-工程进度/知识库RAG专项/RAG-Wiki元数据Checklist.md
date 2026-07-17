# RAG Wiki 元数据 Checklist

> 状态：实施中
> 日期：2026-07-17
> 方案：`RAG-Wiki元数据实施方案.md`
> 约束：每个小功能独立使用中文 commit message 提交；不 push；每轮先提交审查报告，再修复报告问题。

## 0. 开工与边界

- [x] 基于 `dev` 创建独立 worktree 与 `codex/rag-wiki-metadata` 分支。
- [x] 阅读根目录 `AGENTS.md`、`DESIGN.md` 与相关 UI / i18n 规范。
- [x] 只读检查 `docs/功能实现总览.md` 和 `docs/1-立项/开发前问题清单.md`。
- [x] 确认不修改已发布 v7 RAG schema，不新增 migration。
- [x] 确认不抓 Wiki 正文、不新增 Wiki 分片或 `{metadataSection}`。
- [x] 确认不执行打包、发布、上传和 push。

## 1. 方案与清单

- [x] 固化统一 `WikiContextService` 与 cache-first 语义。
- [x] 固化启动扫描、新入库触发、有界并发、去重和账号切换取消语义。
- [x] 固化 Wiki 只写现有 `metadata:0` 且索引构建不联网。
- [x] 固化最终命中仓库必带完整 Metadata、精简 fallback 与无重复语义。
- [x] 固化 Metadata 不可删除/排除与 Wiki 链接点击语义。
- [x] 新增并提交 `RAG-Wiki元数据实施方案.md`。
- [x] 新增并提交本 Checklist。

## 2. Wiki 缓存与统一读取

- [x] 详情页改用 `WikiContextService`，不再直接请求 Wiki API。
- [x] 全局搜索详情改用 `WikiContextService`，不再直接请求 Wiki API。
- [x] Repo AI Chat 与 Companion 使用相同 cache-first 入口。
- [x] fresh 只读缓存，stale 先返回旧值再刷新，miss 先返回空再入队。
- [x] 只保留 indexed 且为 `http` / `https` 的 DeepWiki、ZRead、CodeWiki 链接。
- [x] 私有仓库不向外部 Wiki 服务发送 identity。
- [x] 所有成功刷新结果写入 `DiskWikiCache`。
- [x] 补齐统一读取、TTL、URL 过滤和私有仓库测试。

## 3. cache-first 后台补齐

- [x] 新增 Wiki 后台补齐协调器与小并发队列。
- [x] 排队与执行期间按 repo identity 去重。
- [x] App 当前数据库就绪后扫描已有知识库仓库。
- [x] 新仓库加入知识库后自动入队。
- [x] fresh 缓存跳过，stale/miss 入队，失败静默降级并由 TTL 重试。
- [x] 账号/数据库切换取消旧任务、清空队列并阻止旧 generation 写入新库。
- [x] 私有仓库在入队和执行边界均被拒绝。
- [x] 补齐并发、去重、启动扫描、新入库、失败与账号切换测试。

## 4. Metadata Wiki 内容与精确重建

- [x] 扩展 `RAGMetadataSnapshot`，携带三类有效 Wiki 链接。
- [x] `RAGChunkBuilder.buildMetadata` 按固定顺序输出 Wiki 行并省略空值。
- [x] `KnowledgeRAGIndexBuilder` 只读 `DiskWikiCache`，不等待网络。
- [x] Wiki 缓存保存/更新后只刷新对应 repo Metadata。
- [x] 清空 Wiki 缓存后刷新受影响 Metadata 并移除链接。
- [x] 无内容变化时不产生无意义 chunk/embedding 工作。
- [ ] 补齐 Metadata 输出、缓存读取、精确重建和清缓存测试。

## 5. Prompt 必带完整 Metadata

- [x] Repository 批量读取最终仓库有效 `metadata:0`，包含 `keyword_only`。
- [x] Retriever 将完整 Metadata 作为 repo bundle 固定上下文头，不新增 hit/score/citation。
- [x] 完整 Metadata 可用时不输出精简元数据。
- [x] Metadata 缺失或被排除时使用精简元数据兜底。
- [x] Metadata 自身命中时不重复输出。
- [x] `structured_only` 保持现有精简元数据语义。
- [x] evidence 预算优先保留最终仓库完整 Metadata，再裁剪普通分片。
- [x] 空间不足时减少最终仓库，不保留“无 Metadata 仓库”。
- [x] 维持没有独立 `{metadataSection}`，不改变 RepoContext 独立占位符。
- [ ] 补齐完整优先、fallback、无重复、structured-only、预算和 citation 测试。

## 6. Metadata 禁删与 Wiki 链接 UI

- [x] Metadata 行不显示删除按钮。
- [x] ViewModel / service 拒绝 Metadata 软删除、排除与永久删除。
- [x] Repository / domain 再次拒绝 Metadata 删除和排除。
- [x] 其它分片删除、恢复与永久删除行为保持不变。
- [x] Metadata 仍可查看和编辑 override。
- [x] Metadata 行展示 DeepWiki、ZRead、CodeWiki 紧凑链接。
- [x] 链接解析只接受 `http` / `https`，点击使用系统浏览器。
- [x] 回答 Markdown 外链继续使用现有打开路径。
- [x] 补齐禁删防线与 Wiki 链接解析测试。

## 7. i18n、正式文档与自动化

- [x] 新增固定文案进入 `Localizable.xcstrings`，en / zh-Hans 完整。
- [x] 更新 `docs/3-设计/详细设计/30-本地RAG设计.md`。
- [x] 更新 `docs/1-立项/开发前问题清单.md`，记录 Wiki Metadata 决策。
- [x] 更新 `知识库RAG专项进度.md`，不伪造人工验收。
- [x] 不修改 `docs/功能实现总览.md`，仅起草待确认同步内容。
- [ ] `jq empty Starcat/Resources/Localizable.xcstrings` 通过。
- [ ] `git diff --check` 与 i18n 禁用调用扫描通过。
- [ ] RAG / Wiki 定向测试通过。
- [ ] 全量 `Starcat` test 通过。
- [ ] `Starcat` 与 `StarcatDirect` Debug build 通过。

## 8. 第一轮审查：架构与数据边界

- [ ] 先新增并提交第一轮审查报告。
- [ ] 核对统一 Wiki 入口、私有仓库、TTL、并发、去重和账号隔离。
- [ ] 核对缓存事件、Metadata 精确重建、索引不联网和 schema 边界。
- [ ] 核对 Prompt bundle、完整/精简 Metadata 与 citation/hit 语义。
- [ ] 报告问题逐项修复并按小功能提交。
- [ ] 修复后重跑相关测试并回填报告。

## 9. 第二轮审查：UI、Prompt 与兼容行为

- [ ] 先新增并提交第二轮审查报告。
- [ ] 核对 Metadata 多层禁删且其它分片行为未回归。
- [ ] 核对 Wiki 链接展示、点击与回答 Markdown 外链。
- [ ] 核对 Metadata 预算优先级、无重复、structured-only 和 RepoContext 占位符不受影响。
- [ ] 核对 i18n、明暗主题、focus 与可访问性规范。
- [ ] 报告问题逐项修复并按小功能提交。
- [ ] 修复后重跑相关测试并回填报告。

## 10. 第三轮审查：测试、文档与工程一致性

- [ ] 先新增并提交第三轮审查报告。
- [ ] 对照方案、代码、测试、i18n、专项进度和 Checklist 逐项检查。
- [ ] 只读核对 `docs/功能实现总览.md` 并起草待确认同步内容。
- [ ] 核对所有小功能与审查修复均有独立中文 commit。
- [ ] 执行最终定向测试、全量测试、双 target build 与静态检查。
- [ ] 报告问题逐项修复并按小功能提交。
- [ ] 修复后再次执行最终门禁并回填报告。

## 11. 最终收口

- [ ] 至少三轮审查完成，最后一轮无新增功能缺口。
- [ ] 本 Checklist 全部可自动验证项已回填。
- [ ] 无法自动观察的人工 UI 验收项明确保留，不伪造完成。
- [ ] 新增并提交 `RAG-Wiki元数据结果报告.md`。
- [ ] 结果报告列出实现、验证、提交、已知边界和总览待确认草案。
- [ ] 确认未 push。
