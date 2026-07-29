# 仓库洞察 XML 上下文清洁复审报告

> 日期：2026-07-30  
> 范围：当前 HEAD 的代码、测试、设计文档、专项进度、i18n、提交与工作区  
> 结论：未发现新增 P0 / P1 / P2 功能缺口

## 1. 功能与架构

- 页面、仓库 AI 摘要 / 对话和 RAG 共用 `RepositoryInsightsDocument` 与同一 Artifact Storage。
- RAG 缺 Artifact 时只执行 cache-only 本地准备，不额外请求 GitHub 或 Discovery。
- 知识库特殊项顺序、独立统计、只读查看、复制、下载、删除、重新生成和稳定生成状态完整。
- 删除失败会保留旧 Artifact；主动生成在切仓、移库和关窗时真正取消内部任务，迟到结果不写盘。
- Prompt、预算、合法 XML 投影、证据门禁、citation 与全部 Inspector 可见面一致。
- 历史仅保存审计 metadata；repo/source/xml hash 不匹配时不回放正文。

## 2. 数据与兼容

- 没有数据库 migration，没有修改 `RAGChunkSource`，已发布 `v7-knowledge-rag` 不变。
- Artifact 删除不影响 Repository Insights SQLite、Star History、AI Summary 或仓库数据。
- XML 不进入 `rag_chunks`、embedding、CloudKit、External Search query 或普通会话正文。
- 旧会话与旧 Prompt 配置保留兼容解码 / 默认值迁移，自定义 Prompt 不被覆盖。

## 3. 自动化证据

- Repository Insights Context / Storage / Coordinator / RAG 定向测试通过。
- 全部 Repository Insights、My Insights、Star History、Repo AI、AppSettings、RepoContext Storage、Knowledge RAG Core 与 Browser 相关测试通过。
- 两轮修复后的当前 HEAD 全量 `StarcatTests` 通过。
- 当前 HEAD `Starcat` Debug 与 `StarcatDirect` Debug build 通过。
- `jq empty`、repositoryInsights en / zh-Hans 完整性、String Catalog 格式和禁用 i18n API 扫描通过。
- 每次小功能提交前均执行目标文件 `git diff --check`；当前工作区 diff check 通过。

## 4. 文档与进度

- `开发前问题清单`、RAG 详细设计、洞察中心详细设计和 RAG 专项进度与代码一致。
- 三轮审查报告均已先于对应修复提交，问题和复验结果均已回填。
- `docs/功能实现总览.md` 未修改，待确认草案将在结果报告提供。
- 用户并行工作的 2 个已修改文档和 3 个未跟踪文档未被暂存、提交或回退。

## 5. 人工验收边界

本任务没有启动 Starcat，也没有伪造人工 UI 验收。仍需 dong4j 在真实 App 中确认：

- 知识库特殊项的查看、复制、下载、删除与重新生成。
- 切仓 / 关窗期间主动生成取消的视觉反馈。
- 真实 Provider 下 AI / RAG Prompt、Evidence 与历史回放。
- Light / Dark、最小窗口、Reduce Motion、VoiceOver 等完整矩阵。

上述人工项不阻塞本轮代码与自动化交付结论，但在产品验收记录中继续保持未完成。
