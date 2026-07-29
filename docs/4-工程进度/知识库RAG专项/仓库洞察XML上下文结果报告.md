# 仓库洞察 XML 上下文结果报告

> 日期：2026-07-30  
> 状态：代码、自动化、三轮整改与清洁复审完成；人工 UI 验收待执行  
> 分支：`dev`  
> 推送：未 push

## 1. 交付结果

本需求已把仓库洞察从“页面内临时统计”收口为可复用的结构化能力：

1. 仓库洞察页面、仓库 AI 摘要 / 对话和知识库 RAG 共用 `RepositoryInsightsDocument`。
2. 结构化快照稳定渲染为合法 `<repository_insights>` XML，包含 source/xml hash、数据新鲜度和受控聚合指标。
3. 独立 Storage 原子保存 `insights.xml` 与 metadata，支持校验、零重复写盘、single-flight、账号边界、删除抑制和主动重建。
4. 仓库 AI 先触发时可正常准备洞察缓存；页面后打开时复用同一数据和 Artifact。
5. RAG 缺 Artifact 时只允许 cache-only 本地生成，不会为一次问答新增 GitHub / Discovery 请求。
6. 知识库详情按 Metadata → Insights XML → RepoContext XML → 普通分片展示，洞察 XML 支持只读查看、复制、下载、删除和重新生成。
7. 洞察 XML 使用独立 Prompt section、token 预算、合法 XML 投影、citation 和证据门禁。
8. Plan、Timeline、Context、Evidence、Debug 和历史回放均具备洞察专用审计信息。

## 2. 架构与扩展边界

核心数据流：

```text
Repository Insights Providers / SQLite / Star History
  → RepositoryInsightsSnapshot
  → RepositoryInsightsDocument
  → RepositoryInsightsContextCoordinator
  → RepositoryInsightsContextStorage
  ├─ Repository Insights 页面
  ├─ 仓库 AI 摘要 / 对话
  └─ Knowledge RAG cache-only loader
       → XML projector
       → {repositoryInsightsSection}
       → citation / Inspector / history audit
```

该设计已经为后续特殊仓库上下文扩展保留清晰边界：

- 结构化模型、Renderer、Storage、生命周期协调和 RAG 适配相互独立。
- 特殊上下文通过独立 RAG document / snapshot / citation / usage segment 扩展，不污染普通 chunk domain。
- 没有新增 `RAGChunkSource`，没有修改数据库 migration，已发布 `v7-knowledge-rag` 保持不变。
- XML 不写 `rag_chunks`，不 embedding，不进入 CloudKit、External Search query 或普通消息正文。
- 删除只影响 Artifact，不删除 Repository Insights SQLite、Star History、AI Summary 或仓库数据。

## 3. 审查发现与修复

| 轮次 | 发现 | 修复 |
|---|---|---|
| 第 1 轮 | 删除失败被吞掉，UI 可能误显示已删除 | 删除改为错误传播；失败保留旧 Artifact 并显示双语反馈 |
| 第 2 轮 | 切仓 / 关窗只取消 UI Task，内部主动生成仍可能联网写盘 | 增加 repo + scope + mode 定向取消；写盘前再次检查取消 |
| 第 3 轮 | 两次修复后的全量门禁证据过期，正式文档仍标记复审中 | 当前 HEAD 重跑全量测试 / 双 build，并同步设计与进度 |
| 清洁复审 | 无新增 P0 / P1 / P2 | 无需继续修改代码 |

详细证据：

- `仓库洞察XML上下文审查报告-第1轮.md`
- `仓库洞察XML上下文审查报告-第2轮.md`
- `仓库洞察XML上下文审查报告-第3轮.md`
- `仓库洞察XML上下文清洁复审报告.md`

## 4. 自动化结果

以下门禁均在本需求代码上通过；两次审查修复后又在当前 HEAD 重新执行全量门禁：

- Repository Insights Context Models / Storage / Coordinator / RAG 定向测试。
- Repository Insights、My Insights、Star History、Remote Provider 与 Cache 全部相关测试。
- Repo AI、AppSettings Prompt、RepoContext Storage、Knowledge RAG Core 与 Browser 相关测试。
- 全量 `StarcatTests`。
- `Starcat` Debug build。
- `StarcatDirect` Debug build。
- `xcodegen generate`。
- `jq empty Starcat/Resources/Localizable.xcstrings`。
- repositoryInsights 新增 key 的 en / zh-Hans 完整性与 String Catalog 格式。
- 禁用 `String(localized:)` / `NSLocalizedString` 调用扫描；命中仅为项目说明注释。
- 目标文件与当前工作区 `git diff --check`。

本任务没有启动 Starcat。真实 UI 点选、主题、Reduce Motion、VoiceOver 和真实 Provider Prompt 仍由 dong4j 验收，未伪造完成人工证据。

## 5. 关键提交

### 功能

- `4afe7ac`：生成结构化仓库洞察 XML 文档。
- `5d69853`：持久化仓库洞察 XML 产物。
- `26f545c`：统一协调洞察 XML 生成生命周期。
- `8e0ea5d`：仓库 AI 共用洞察 XML。
- `e2dd5b7`：页面刷新后同步洞察 XML。
- `43b76a3`：知识库管理洞察 XML 特殊分片。
- `8822c45`：准备 RAG 洞察 XML 上下文。
- `eee1e92`：注入独立 Prompt section。
- `3af5e76`：接入 RAG Service 链路。
- `e09ceae`：展示并安全回放洞察 XML。
- `1ce8d5f`：补齐特殊 XML 生成所有权门禁。

### 审查修复

- `9d1a584`：保留删除失败的洞察 XML 产物。
- `f48aa80`：真正取消洞察 XML 主动生成。

### 文档与审查

- `dcac7e1`：实施方案与 Checklist。
- `625c21c`、`cd74ba4`：RAG / 洞察正式设计。
- `8f98771`、`83821a4`、`4cf0943`：三轮审查报告。
- `423dd10`：清洁复审报告。

其余进度回填均使用独立中文规范提交。整个过程没有 push。

## 6. 工作区状态

本专项文件全部已提交。工作区仍有以下并行工作，均未被本任务暂存、提交或回退：

- `docs/2-产品/需求讨论/agent/00-概览-Agent方向讨论与方案.md`
- `docs/2-产品/需求讨论/agent/20-CLI-Agent作为AI-Provider初步方案.md`
- `docs/3-设计/详细设计/README.md`
- `docs/3-设计/详细设计/54-Starcat外部应用插件化集成扩展初步方案.md`
- `docs/3-设计/详细设计/55-macOS桌面小组件初步方案.md`

## 7. `docs/功能实现总览.md` 待确认草案

按照项目铁律，本任务没有修改 `docs/功能实现总览.md`。建议 dong4j 验收后确认写入以下内容：

```markdown
- [x] **仓库洞察 XML 共用 AI / RAG 上下文** — 页面、仓库 AI 与知识库 RAG 共用只读特殊 XML Artifact — `Starcat/Features/Insights/RepositoryInsightsContext*.swift`、`Starcat/Features/RAG/**` — 2026-07-30
> 实现：以 RepositoryInsightsDocument 统一结构化快照与 XML，独立 Storage 管理可删除 Artifact；RAG 仅 cache-only 读取并走独立预算、citation 与历史审计，不新增 schema 或向量化，人工 UI 验收待执行。
```

建议变更日志草案：

```markdown
- 2026-07-30 03:10: 完成仓库洞察 XML 与仓库 AI、知识库 RAG 共用及特殊分片管理
```

只有 dong4j 明确回复“可以写总览 / 同步总览”后才能写入。
