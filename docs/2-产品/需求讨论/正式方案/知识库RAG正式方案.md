# 知识库 RAG 正式方案

> 日期: 2026-07-03
> 状态: 正式方案
> 范围: 知识库 RAG 的产品定位、数据范围、入口 UI、回答体验与实施原则

## 1. 方案目标

把早期“已 star 仓库本地 RAG”调整为“知识库 RAG”。

新的目标是:

> 让用户基于 Starcat 私有知识库中的 repo 进行自然语言问答,获得带引用、可追溯、可回到 repo 继续阅读的答案。

这次调整的核心不是新增一个聊天框,而是把 RAG 的知识源边界与 Starcat 已落地的知识库语义对齐。

## 2. 产品原则

1. 知识库是 RAG 默认唯一数据源。
2. Starred 是来源和搜索范围,不是 RAG 默认回答范围。
3. RAG 是跨 repo 问答,不是单仓库摘要。
4. RAG 输出必须可追溯,每个关键结论都能回到 repo 和 chunk。
5. RAG 第一版只读,不自动写 tags、notes、status、star 或 libraryState。
6. 资料不足时明确说不足,不编造 repo、API 或结论。
7. UI 要让用户始终知道当前回答基于“知识库”,不是 GitHub 全网。
8. issues / releases / PR 等网络数据只能作为本轮远程临时上下文,不进入本地 RAG 索引。
9. 检索主链路采用 Local-First Hybrid RAG: 本地 FTS + 本地向量默认可用,外部服务只是高级选项。

## 3. 数据范围

### 3.1 默认范围

RAG 默认候选集:

```sql
repo_notes.library_state = 'in_library'
```

这包含:

- 已 star 且已入库 repo。
- 未 star 但已入库 repo。

不包含:

- 已 star 但未入库 repo。
- GitHub 搜索结果。
- Trending / Discovery / Weekly 中未入库的远端 repo。
- AnySearch web 结果。

### 3.2 与语义搜索范围的差异

语义搜索继续保留三种范围:

| 范围 | 用途 |
|---|---|
| `starred` | 管理 GitHub Stars 时找 repo |
| `knowledge` | 在知识库里找 repo |
| `all` | starred 与知识库并集,用于全局找回 |

RAG 默认只使用 `knowledge`。原因是 RAG 不是“找候选”,而是“生成答案”。生成答案需要更高信任边界。

### 3.3 例外和调试能力

第一版产品 UI 不提供“把 starred 也纳入 RAG 回答”的默认开关。

后续可以在 Debug 或高级设置里保留诊断入口,用于比较:

- 知识库范围回答。
- starred 范围回答。
- all 范围回答。

但正式产品文案仍以“知识库问答”为主,避免用户误以为 RAG 会引用所有 GitHub Stars。

### 3.4 远程临时上下文

第一版不做通用联网 web RAG,但实现受控的 GitHub 远程临时上下文。Query Planner 只声明
issues / PR / releases / contributors / commit activity / security advisories 等现场数据需求;
本地候选 repo 确定后,必须由用户确认资源 chips,再对保留项发起请求。

适用场景:

| 用户问题 | 临时上下文 |
|---|---|
| “这些项目最近有没有集中反馈的问题?” | GitHub Issues |
| “最近 release 有没有 breaking change?” | GitHub Releases |
| “哪个项目维护更活跃?” | Pull Requests / commit activity |
| “有没有安全公告或漏洞风险?” | Security Advisories |

约束:

- 必须先由知识库范围筛出候选 repo。
- 只能对知识库 SQL 候选 repo 拉取,GitHub Search 响应还要二次校验 repo 归属。
- 远程数据不进入 `rag_chunks`,不生成 embedding,不进入 CloudKit。
- 非 UI 调用方没有提供确认器时默认全部跳过,不能静默批准联网。
- 失败时降级为“仅基于本地知识库回答”,不能让整轮问答失败。

## 4. 信息架构与入口

### 4.1 推荐入口

新增独立“知识库问答”工作台,与 Agent Workspace 同级。

入口候选:

| 入口 | 第一版建议 | 说明 |
|---|---:|---|
| 主 toolbar `知识库问答` / `Ask` 按钮 | 推荐 | 可见性高,适合高频使用 |
| Smart Collections -> 知识库页顶部动作 | 推荐 | 与数据范围强绑定 |
| Debug 菜单 gate | 推荐用于未稳定阶段 | 与 Agent 当前入口策略一致 |
| 搜索框 mode | 不推荐第一版 | 搜索和问答心智不同 |
| Agent rail 内一个 Agent | 不推荐作为主入口 | RAG 是常用问答,不是一次性任务 |
| 单仓详情页 AI 浮层 | 不推荐 | RAG 是跨 repo 问答 |

第一版可以采用:

- Debug 菜单控制 toolbar 入口是否显示。
- toolbar 打开覆盖式 `KnowledgeRAGWorkspace`。
- 知识库集合页提供同一个打开动作。

### 4.2 与 Agent Workspace 的关系

Agent Workspace 已经承担多步骤任务:

- 生成周报。
- 替代品发现。
- 重叠扫描。
- Untagged 整理。
- Release 影响分析。

知识库 RAG 的主线是问答:

- 提问。
- 召回知识库证据。
- 生成回答。
- 展示引用。
- 支持追问。

两者可复用 Run Surface 思路,但不合并入口:

| 维度 | Agent Workspace | 知识库 RAG |
|---|---|---|
| 使用心智 | 执行任务 | 问知识库 |
| 过程展示 | steps / tools / artifacts / confirmations | retrieve / evidence / answer / citations |
| 输出 | artifact / report / action plan | streaming answer / citation set |
| 写入动作 | 未来可经确认写入 | 第一版只读 |
| 历史 | 任务历史 | 问答会话历史 |

## 5. 工作台 UI

### 5.1 布局

采用覆盖式工作台:

```text
┌────────────────────────────────────────────────────────────┐
│ 左侧: 会话与范围        │ 中间: 问答流          │ 右侧: 证据 │
│ - 新会话               │ - 用户问题            │ - 引用 repo │
│ - 历史会话             │ - streaming 回答      │ - chunk     │
│ - 当前范围: 知识库      │ - 追问输入            │ - 来源类型  │
│ - 索引覆盖率            │ - 空状态 / 错误        │ - 打开详情  │
└────────────────────────────────────────────────────────────┘
```

### 5.2 顶部状态

工作台顶部显示:

- 当前范围: `知识库`。
- 知识库 repo 数。
- RAG chunk 索引覆盖率。
- 当前模型。
- 只读标识。

示例:

```text
知识库问答 · 126 repos · RAG 索引 92% · GPT-4.1 · 只读
```

### 5.3 空状态

| 状态 | UI 引导 |
|---|---|
| 知识库为空 | 引导去 Smart Collections -> 知识库,或从 Search/Discovery/Trending 加入知识库 |
| 知识库有 repo 但无 RAG 索引 | 引导去 Settings -> AI 开始构建 RAG 索引 |
| 缺少 embedding API key | 引导配置 Embedding 任务 |
| 缺少 chat API key | 引导配置对话/摘要任务 |
| 当前问题无命中 | 展示“知识库中没找到足够资料”,提供 GitHub / AnySearch 搜索、拉取候选 repo 临时上下文等动作 |

### 5.4 Command Composer

中间问答输入区采用 Command Composer,而不是普通输入框。它承担“把用户显式意图变成结构化上下文”的职责。

核心能力:

| 能力 | 交互 | RAG 语义 |
|---|---|---|
| `@repo` | 输入 `@` 弹出知识库 repo list | 指定一个或多个 repo 作为本轮候选上下文 |
| 模型切换 | 输入框内模型下拉 | 本轮或当前会话切换模型,不改全局设置 |
| 图片/附件 | 拖拽或点击上传 | 作为本轮临时上下文,不进入知识库索引 |
| GitHub 链接 | 自动识别 repo 链接 | 本地已有 repo 新开本地详情窗口,否则打开 GitHub |

`@repo` 是最高优先级的易用性能力。用户输入:

```text
@groue/GRDB.swift @stephencelis/SQLite.swift 对比一下桌面 app 里怎么选
```

系统应理解为“只在这两个 repo 中对比”,而不是再从整个知识库自由召回。只有当用户表达“参考这个项目,再找类似项目”时,才把 mention repo 当作偏好上下文而不是硬范围。

Composer 顶部展示上下文 chips:

- `Repo: owner/name`
- `Mode: only / prefer / exclude`
- `GitHub Issues`
- `Model: GPT-4.1`
- `Attachment: screenshot.png`

用户删除 chip 后,本轮执行上下文必须同步变化。

issues / releases 等远程临时上下文不通过输入框命令触发。系统应由 Query Planner 根据用户问题判断是否需要,再通过 Query Plan chips 或确认步骤展示给用户;用户可以删除对应 chip 来跳过该远程上下文。

附件和图片第一版可以分阶段落地: 先做 UI 与数据结构,再逐步接入 vision 和文本/PDF 提取。无论哪一阶段,附件都只属于本轮会话,不进入 RAG chunk 索引。

## 6. 回答体验

### 6.1 回答结构

RAG 回答默认包含:

1. 直接答案。
2. 证据支持的 repo 列表或对比表。
3. 引用 chip。
4. 资料不足提示。
5. 可选下一步建议。

回答必须用引用标注关键 repo:

```markdown
如果你要在 macOS 原生应用里做本地数据库,知识库里最相关的是 GRDB.swift [groue/GRDB.swift]。
```

### 6.2 引用与证据

每个引用必须来自检索到的 chunk。

引用 chip 至少展示:

- `owner/name`
- 来源类型: README / Notes / AI Summary / Description
- section path
- 相似度或召回原因

点击引用:

- 右侧 Inspector 切换到该引用详情,展示对应 chunk、section、来源、相似度和命中方式。
- “打开详情”优先复用现有本地 repo 详情页新窗口;本地没有该 repo 时打开 GitHub repo 页面。

### 6.3 证据 Inspector

右侧 Inspector 用于增强可信度,不是装饰面板。

MVP 不做“证据 / 检索 / 远程上下文”等 tab。右侧只保留单一“引用”面板,避免把第一版做成调试工具。

引用面板结构:

1. 当前选中引用详情: repo、来源类型、section path、相似度或召回原因、命中方式。
2. chunk 预览: 展示该 citation 绑定的 matched child 原文;必要时补充 section parent 标题。
3. 其他引用列表: 展示本轮回答实际引用过的其它 repo / chunk,点击后切换上方详情。
4. 操作: “打开详情”优先新开本地 repo 详情窗口;本地没有该 repo 时打开 GitHub。

底层仍保留 `matchedChildren`、`sectionParents`、`hitKind`、`score` 等数据,但默认 UI 不单独展示 Retriever pipeline、keyword/vector/fusion 调试列表。后续如需要排障,可放 Debug gate 或日志,不进入普通用户界面。

## 7. 多轮对话

第一版支持同一会话内追问,但检索策略保持可控:

- 每个用户新问题默认重新 retrieve。
- 追问会携带最近 N 轮消息摘要,但不直接复用上一轮 chunks 作为唯一依据。
- 如果用户点击“基于上一组证据继续问”,才锁定上一轮 citation set。

理由:

- 知识库范围内问题变化可能很大,默认复用上一轮 chunks 容易把答案锁死。
- RAG 的可信度来自“每轮问题都有自己的证据集”。

## 8. 历史与隐私

RAG 会话历史只保存在本地。

MVP 需要保存完整问答历史,但 citation 不保存完整 chunk 内容快照。

建议保存:

- 用户问题。
- 模型回答。
- cited repo ids。
- cited chunk ids。
- citation source / section title / score / hit kind。
- 使用模型。
- 创建时间。
- 当前知识库范围 snapshot hash。

不进入 CloudKit 第一版同步。

引用片段内容不做快照保存。历史回看时优先读取当前 `rag_chunks` 内容;如果 chunk 已被清理,显示“引用片段已清理或需要重建索引”。

远程临时上下文不作为会话长期资料保存。真实远程上下文启用后,最多保存本轮回答中可审计的 source URL、resource、fetchedAt 和降级状态;不保存完整 issues body 作为历史知识资产。

用户在 Command Composer 上传的图片和附件也只属于本轮临时上下文。除非后续另做“导入知识库”功能,否则附件不进入 RAG 索引、repo notes、AI summary 或 CloudKit。

清理入口放在 Settings -> Storage,与 AI 对话历史同级。

## 9. 设置项

第一版设置尽量少:

| 设置 | 默认 | 说明 |
|---|---|---|
| RAG 索引构建 | 手动 / 后台慢速 | Settings -> AI 或 Storage 显示 |
| 检索后端 | Local | 默认本地 FTS5 + 本地 embedding 表 |
| 每次召回 chunk 数 | keyword 30 + vector 30 | 不建议直接暴露给普通用户,可放高级设置 |
| 每 repo 最大 chunk 数 | 3 | 防止单个 README 垄断上下文 |
| 回答上下文 token 上限 | 12000 | 控制成本 |
| 是否保存会话历史 | 开 | 可在 Storage 清空 |

### 9.1 高级自托管组件

Meilisearch 和 Qdrant 作为第一版高级可选后端提供,但不是使用 RAG 的前置条件。

| 组件 | 角色 | 配置入口 | 默认状态 |
|---|---|---|---|
| SQLite + FTS5 | 本地 keyword search | 内置 | 开启 |
| SQLite embedding table | 本地 vector search | 内置 | 开启 |
| Meilisearch | 自托管 keyword / hybrid search provider | Settings -> AI -> RAG Backend | 关闭 |
| Qdrant | 自托管 vector store provider | Settings -> AI -> RAG Backend | 关闭 |

Settings 交互要求:

- 默认展示“Local RAG Backend”,普通用户无需配置。
- 高级开关打开后,才展示 Meilisearch / Qdrant endpoint、API key、index / collection。
- 提供“测试连接”按钮,检查 endpoint 和认证;已有 Qdrant collection 还要校验 named vector,
  首次不存在的 index/collection 在重建时创建。
- provider 切换后,如果现有索引不可复用,提示需要重建索引。
- 外部 provider 的 API key 存 Keychain。
- 私有 repo 默认安全模式是不上传代码内容到云 embedding 或远程 RAG provider。

不做:

- 不让用户在普通 UI 调复杂 reranker。
- 不让用户手工选择 embedding 表。
- 不在第一版做多知识库空间。

## 10. Pro 与成本边界

RAG 属于 Pro 能力,因为它需要:

- embedding 索引。
- chat 生成。
- 本地历史与证据视图。

成本提示要清楚:

- 构建 RAG chunk 索引会调用 embedding API。
- 每次提问会调用 chat 模型。
- 默认检索在本地执行;启用 Meilisearch / Qdrant 后,检索请求和必要 payload 会发送到用户配置的自托管服务。
- 问题需要 issues / releases / PR 等现场信息时,用户确认后才调用 GitHub API 拉取本轮候选 repo 的临时上下文。
- 如果用户上传图片或附件,会随本轮请求发送给所选模型。OpenAI-compatible 服务没有统一的
  vision capability 字段,Starcat 不按模型名猜测;服务端拒绝时原样展示错误并允许用户切换模型或移除图片。
- 如果知识库很大,首次索引耗时较长。

UI 不应夸大费用估算,只给用户可理解的提示:

```text
首次构建会读取知识库 README、笔记和摘要并生成向量索引。之后只对变化的内容增量更新。
```

## 11. 不做范围

第一版不做:

- 不引用未入库 starred repo。
- 不做通用联网 web RAG;只允许对本轮候选 repo 拉取受控的远程临时上下文。
- 不自动把回答结果写入 notes/tags/status。
- 不自动推荐或移除知识库 repo。
- 不做复杂本地 reranker 模型。
- 不要求用户必须部署 Meilisearch / Qdrant。
- 不做多用户共享知识库。
- 不做 CloudKit 同步 RAG 会话历史。
- 不把 RAG 混进 Agent Workspace 作为唯一入口。

## 12. 实施顺序

推荐分 8 个阶段:

1. 数据与索引: 新增 chunk-level RAG 索引,默认只覆盖知识库。
2. Retriever: FTS + vector hybrid retrieval,输出 chunk citations 和命中方式。
3. Remote Context: 对候选 repo 提议并确认 issues / releases / PR 等远程临时上下文,支持逐资源降级。
4. Generator: RAG prompt、streaming 回答、引用解析。
5. Command Composer: `@repo`、模型下拉、附件 chip、GitHub 链接识别。
6. Workspace: 独立覆盖式知识库问答 UI。
7. 历史与导出: 保存完整本地问答历史和 citation metadata,支持复制与导出 Markdown。
8. 质量增强: Meilisearch / Qdrant 可选 provider、证据过滤和后端回退;reranker、Agent 联动另立专项。

## 13. 成功标准

第一版完成后应满足:

- 用户能打开知识库问答工作台。
- 用户能用 `@repo` 显式指定一个或多个 repo 做对比分析。
- 用户能在输入区看到并删除本轮上下文 chips。
- 系统只从 `libraryState == .inLibrary` 的 repo 召回证据。
- 用户提问后能看到 streaming 回答。
- 回答包含可点击引用。
- 右侧 Inspector 能看到 chunk 证据;使用远程临时上下文时能看到 source URL、fetchedAt 和降级状态。
- 知识库为空、索引缺失、API key 缺失、无命中都有清晰状态。
- 不发生任何自动写库动作。
