# agents-radar 公共雷达与本地定时 Agent 方案

> **文档定位**：记录 `agents-radar` 的真实工作原理，以及 Starcat “短期集中生成、静态分发”与“长期用户本地定时 Agent”两阶段落地方案。
> **状态**：方案已沉淀，尚未授权实现。短期不改 Agent 工作台，长期定时任务也仍需单独立项。
> **调研基线**：2026-08-31，上游仓库 commit `c51388d9726c6064154b73e40ea6fe6c2f7416bd`。
> **关联文档**：
> - [`17-GitHubWeeklyReportAgent技术实现方案.md`](17-GitHubWeeklyReportAgent技术实现方案.md)
> - [`../../../3-设计/详细设计/57-Agent工作台与统一能力层详细设计.md`](../../../3-设计/详细设计/57-Agent工作台与统一能力层详细设计.md)
> - [`../正式方案/Weekly多来源扩展与AI情报采集正式方案.md`](../正式方案/Weekly多来源扩展与AI情报采集正式方案.md)

---

## 一、结论与阶段边界

`agents-radar` 不是 Agent Runtime，而是一条“定时采集 → LLM 生成 → Markdown 归档 → 静态分发”的公共内容生产线。它的 Cloudflare Worker MCP 仅是为 Claude、Codex 等 MCP Client 提供的协议适配层，不参与报告生成，也不是 Web UI 的必经后端。

Starcat 建议分两阶段建设：

| 阶段 | 产品形态 | 生成位置 | 展示位置 | 用户是否需要 AI Key |
|---|---|---|---|---|
| 短期 | **公共 AI Radar** | Starcat 官方 fork 的 GitHub Actions | 主窗口「探索 → AI Radar」 | 否 |
| 长期 | **我的雷达** | 用户 Mac 上的 Starcat Agent Runtime | Agent 工作台 | 是，走用户 BYOK / 已配置 Provider |

两者不是相互替代的双轨实现，而是两种语义不同的内容源：

- **公共雷达**：所有 Starcat 用户看到相同内容，开箱即用，App 关闭时仍能由 GitHub Actions 生成。
- **我的雷达**：用户自行选择主题、来源、语言、时间和 AI Provider，在本地生成个性化 Markdown Artifact。

---

## 二、agents-radar 的真实工作原理

### 2.1 总体数据流

```text
GitHub Actions 定时触发
  ↓
Node.js 并行采集 GitHub / HN / ArXiv / Hugging Face 等来源
  ↓
LLM 生成摘要、比较与中英文报告
  ↓
写入 digests/YYYY-MM-DD/*.md
  ↓
生成 manifest.json 与 feed.xml
  ↓
提交回 GitHub 仓库
  ↓
GitHub Pages 静态分发
  ├─ Web UI 直接读取
  ├─ Starcat 可以直接读取
  └─ Cloudflare Worker MCP 从同一个 Pages 源读取
```

上游证据：

- [GitHub Actions Workflow](https://github.com/duanyytop/agents-radar/blob/master/.github/workflows/daily-digest.yml)
- [Manifest 生成脚本](https://github.com/duanyytop/agents-radar/blob/master/src/generate-manifest.ts)
- [历史 Markdown 目录](https://github.com/duanyytop/agents-radar/tree/master/digests)
- [线上 manifest.json](https://duanyytop.github.io/agents-radar/manifest.json)

### 2.2 GitHub Actions 负责生产，不负责展示

Workflow 定时执行采集和 LLM 生成，产物保存为：

```text
digests/
└─ 2026-08-31/
   ├─ ai-cli.md
   ├─ ai-cli-en.md
   ├─ github-trending.md
   └─ ...
```

同一天可以有多份报告，中英文通常使用不同 report ID。报告生成后作为普通静态文件提交回仓库，后续访问不再重新执行 Agent 或 LLM。

### 2.3 manifest.json 是内容目录

`manifest.json` 告诉消费者有哪些日期和报告，其语义类似：

```json
{
  "generated": "2026-08-31T00:54:04.493Z",
  "dates": [
    {
      "date": "2026-08-31",
      "reports": ["ai-cli", "ai-cli-en", "github-trending"]
    }
  ]
}
```

客户端先读取 Manifest，再拼接受控报告地址：

```text
/digests/{date}/{report}.md
```

Markdown 只是展示内容，不应通过解析 Markdown 标题来识别日期、语言或报告类型；这些业务元数据应以 Manifest 为准。

### 2.4 Web UI 是纯静态阅读器

页面地址：

```text
https://duanyytop.github.io/agents-radar/#2026-08-31/ai-cli
```

`#2026-08-31/ai-cli` 是浏览器端 hash，不会发给 GitHub Pages 服务器。页面中的 JavaScript 执行：

```text
读取 URL hash
  ↓
fetch("./manifest.json")
  ↓
确认 date/report 存在
  ↓
fetch("./digests/2026-08-31/ai-cli.md")
  ↓
marked.parse(rawMarkdown)
  ↓
DOMPurify.sanitize(html)
  ↓
展示
```

因此 Web UI 没有在访问页面时运行采集任务，也没有依赖 Cloudflare Worker。实现可见 [index.html](https://github.com/duanyytop/agents-radar/blob/master/index.html)。

---

## 三、Cloudflare Worker MCP 的准确定位

### 3.1 它是 MCP 协议适配器

Web UI 或 Starcat 可直接通过 HTTP 读取 Pages：

```text
Web UI / Starcat
  ↓ HTTP GET
GitHub Pages: manifest.json / Markdown
```

Claude、Codex 等 MCP Client 期望调用 Tool，所以 Worker 把 MCP JSON-RPC 请求翻译为相同的 HTTP GET：

```text
MCP Client
  ↓ MCP JSON-RPC: get_report(date, type)
Cloudflare Worker MCP
  ↓ HTTP GET
GitHub Pages: /digests/{date}/{type}.md
  ↓
Worker 将 Markdown 包装为 MCP Tool Result
```

Worker 当前提供：

| MCP Tool | 实际操作 |
|---|---|
| `list_reports` | 读取 `manifest.json` |
| `get_report` | 读取指定 Markdown |
| `get_latest` | 从 Manifest 选出最新日期后读取 Markdown |
| `search` | 下载最近报告，逐行执行大小写不敏感字符串匹配 |

`search` 最多查看近 14 天内容，不是 FTS、向量搜索或数据库查询。Worker 对 Manifest 使用约 5 分钟边缘缓存，对报告使用约 1 小时缓存。详见 [mcp/src/index.ts](https://github.com/duanyytop/agents-radar/blob/master/mcp/src/index.ts)。

### 3.2 Starcat 短期不需要它

Starcat 是原生客户端，直接使用 `URLSession` 读取 Manifest 和 Markdown 即可。再经过 Worker MCP 只会额外引入：

- 第二个可用性依赖；
- MCP JSON-RPC 封装和解包成本；
- Worker 运维与版本兼容；
- 对一个本来就是公开静态文件的不必要转发。

只有当未来需要让外部 Agent 通过 MCP 消费 Starcat 公共雷达时，才需要单独保留或重新提供这层 MCP 适配。

---

## 四、短期方案：公共 AI Radar

### 4.1 目标与边界

短期目标是用最小产品链路验证用户是否需要 AI 生态日报：

```text
Starcat 官方 fork
  ↓ GitHub Actions 定时生成
GitHub Pages 静态发布
  ↓ Manifest + Markdown
Starcat 读取、缓存、安全渲染
```

短期明确不做：

- 不修改 Agent 工作台；
- 不在用户 Mac 上采集或调用 LLM；
- 不要求用户配置 AI Key；
- 不将 Node.js 或上游脚本嵌入 App；
- 不依赖公共 Cloudflare Worker MCP；
- 不新建 `starcat-intelligence-api`；
- 不从 Markdown 标题推断业务元数据。

### 4.2 中央生成仓库

建议 fork 到 Starcat 组织并作为独立仓库维护，本地工作区可对应：

```text
supports/starcat-agents-radar/
```

首期保留：

- 多来源采集；
- LLM 摘要与中英文生成；
- `digests/`、`manifest.json`、`feed.xml`；
- GitHub Pages Web UI，作为内容验收和 App 故障时的对照页。

首期可关闭：

- 自动创建 GitHub Issue；
- Telegram 和飞书推送；
- 不用于 Starcat 产品链路的额外分发通道。

LLM 和第三方数据源密钥只放在 GitHub Actions Secrets 中，不进入静态文件和 Starcat 客户端。上游采用 MIT License；如果复制或修改其代码，必须保留版权和许可声明，并按 Starcat 开源致谢规范处理。

### 4.3 静态协议

快速验证阶段直接兼容上游当前协议：

```http
GET /manifest.json
GET /digests/{date}/{report}.md
```

正式产品化前建议新增版本化 `manifest-v1.json`，不覆盖上游旧协议：

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-08-31T00:54:04Z",
  "reports": [
    {
      "id": "ai-cli",
      "date": "2026-08-31",
      "language": "zh-Hans",
      "title": "AI CLI 工具动态",
      "path": "digests/2026-08-31/ai-cli.md",
      "sha256": "...",
      "size": 45678
    }
  ]
}
```

`schemaVersion`、稳定 `id`、语言、标题、文件大小与 checksum 让客户端无需硬编码 report ID，也能在展示前校验下载内容。

### 4.4 Starcat 数据层

建议作为 `Explore` 下的独立只读内容源，不伪装成 Agent Tool：

```text
Starcat/Features/Explore/AIRadar/
  Models/
    AIRadarManifest.swift
    AIRadarReportDescriptor.swift
  Services/
    AIRadarManifestClient.swift
    AIRadarReportClient.swift
    AIRadarCache.swift
  ViewModels/
    AIRadarViewModel.swift
  Views/
    AIRadarContentView.swift
    AIRadarReportListView.swift
    AIRadarReportDetailView.swift
```

职责边界：

| 组件 | 职责 |
|---|---|
| `AIRadarManifestClient` | 请求和解码 Manifest，不读取报告正文 |
| `AIRadarReportClient` | 只读取 Manifest 已声明的 Markdown |
| `AIRadarCache` | 保存可重建的 Manifest 和 Markdown 缓存 |
| `AIRadarViewModel` | 管理日期、类型、语言、加载和错误状态 |

首期不需要新建数据库表。报告是公共、可重建数据，应保存到 Caches 或专用 Application Support 缓存目录，不与用户数据和 CloudKit 混合。

### 4.5 缓存和更新

- Manifest 进入页面时刷新，可使用约 10 分钟 TTL。
- 请求保留 `ETag` / `Last-Modified`，下次使用 `If-None-Match` / `If-Modified-Since`。
- 历史报告可长期缓存；当天报告要允许重新校验，因为 Action 重跑可能覆盖同一路径。
- 新 Manifest 或报告校验失败时，不覆盖最后一份有效缓存。
- 离线时展示最后缓存内容，并标明更新时间。

### 4.6 UI 形态

短期建议放在主窗口：

```text
探索
├─ 每周精选
└─ AI Radar
```

继续使用 Starcat 主窗口三栏语义：

```text
左栏：探索 → AI Radar
中栏：日期、报告类型、语言
右栏：Markdown 报告正文
```

默认选择最新日期，根据 App locale 优先选择中文或英文，并允许用户手动切换。该页面仅阅读公共内容，不出现 Prompt 输入框、Tool Trace 或 Agent Approval。

现有 `RAGMarkdownText` 可作为原生 Markdown 渲染的候选复用点，但实施前必须单独验证原始 HTML、远程图片、外链打开和超长正文性能，不能将公共 Markdown 直接注入未受控 WebView。

### 4.7 安全边界

- 只允许预置 HTTPS 域名，不接受报告内容指定新的下载根域名。
- `date` 必须符合 `YYYY-MM-DD`，`report` 必须来自已验证 Manifest。
- 拒绝 `..`、绝对路径、编码后路径穿越和非 `.md` 路径。
- 限制 Manifest 与单篇 Markdown 最大字节数，建议单篇首期上限 2 MB。
- 不执行 Markdown 内原始脚本，外部链接交给系统浏览器。
- 报告内容不能触发本地 Tool、Agent 或外部写操作。
- 页面需标明“内容由 AI 生成，来源未经 Starcat 逐条独立验证”。

### 4.8 短期验收标准

自动化验证：

- Manifest 解码、版本与非法数据拒绝；
- 受控 URL 拼接、路径穿越和超大响应拒绝；
- ETag / `304 Not Modified` 与离线缓存；
- 新响应损坏时保留最后有效缓存；
- 中英文选择和缺失回退；
- Markdown 危险 HTML、外链和远程图片策略；
- 不触发 Agent Runtime、AI Provider 或用户数据写入。

人工验收：

- 最新日期和 Web UI 展示的报告内容一致；
- 日期、类型、语言切换正确；
- 明暗主题、长文滚动、复制和外链打开正常；
- 断网重启后可继续查看已缓存报告。

工期粗估：中央 fork / Actions / Pages 约 0.5～1 天；Starcat 原生读取、缓存和展示约 2～4 天，总体约 3～5 天形成首个可验证闭环。

---

## 五、长期方案：用户本地定时 Agent

### 5.1 目标

用户可以在 Agent 工作台中创建“我的雷达”，自行选择数据源、主题、语言、运行周期、Agent Runtime 和 AI Provider，每次运行生成一份可审计的本地 Markdown Artifact。

长期不把 `agents-radar` Node.js 工程嵌入 App，而是参考其来源组织、失败降级、LLM 并发限制和 Markdown 产物形态，使用 Starcat 已有 Runtime、Tool、Trace、Approval 和 Artifact 能力实现。

### 5.2 新增通用 Automation 层

定时能力应位于 Agent UI 和 Runtime 之间，而不是在 `LoopAgentRuntime` 或某个 View 中直接增加 `Timer`：

```text
AgentAutomationDefinition
  ↓
AgentAutomationScheduler
  ↓ 到期后创建一次普通 AgentRun
AgentRuntimeRouter / LoopAgentRuntime / External Runtime
  ↓
受控只读 Tools
  ↓
AgentArtifact(type: .markdown)
```

这样每次定时运行都能继续复用已有：

- `AgentRun` 持久化；
- Tool allowlist 和 Approval；
- 运行时间线、Inspector 和 Trace；
- Token、成本、失败原因与产物归档；
- 取消、重试和手动重新运行。

### 5.3 建议数据模型

```text
AgentAutomationDefinition
  id
  agentID
  enabled
  cadence
  nextRunAt
  lastRunAt
  lastRunStatus
  sourceConfiguration
  topics
  language
  runtimePolicy
  providerID
  budgetPolicy
  retentionPolicy
  notificationEnabled
```

Starcat 已经发布正式版，该模型如果需要 SQLite 持久化，必须追加新的 `registerVN` 迁移，不得回写已发布 migration，也不得要求用户删库。

### 5.4 macOS 调度边界

长期建议使用 `NSBackgroundActivityScheduler` 承接机会式后台调度，并增加：

- App 启动后的逾期补跑；
- “立即运行”；
- 按计划周期的唯一键去重；
- 同一 Automation 的单实例租约；
- 网络、电量、Provider 和预算前置检查；
- 失败重试、指数退避与最大尝试次数；
- 测试 host 环境下不注册后台任务。

`NSBackgroundActivityScheduler` 是机会式调度，不能保证每天精确在 07:00 运行。当 Mac 关机、App 不可运行、网络不可用或系统推迟时，只能在后续条件允许时补跑。如果产品承诺“每天准点生成”，公共服务端调度仍是必要的。

### 5.5 结构化数据源

长期不应让 Agent 反复解析公共 Markdown，也不应将上游生成后文本当成唯一事实库。应将采集能力建模为受控只读 Source Tool：

```text
GitHub Trending Source
Hacker News Source
ArXiv Source
Hugging Face Source
Starcat Weekly Source
External Search Source
```

各 Source 统一输出结构化事实：

```text
sourceID
canonicalURL
title
publishedAt
observedAt
rawMetrics
content
```

Agent 在这些事实之上执行筛选、聚类、去重、比较和写作。GitHub 仓库类情报应优先复用已有 `starcat-weekly-api` 和 Weekly 来源，不重新建第二套公共仓库事件 API。

### 5.6 定时执行与产物

每次到期时：

1. Scheduler 检查 enabled、计划唯一键、网络、Provider 和预算。
2. 冻结当次 Automation 配置、Prompt、数据源和 Runtime 快照。
3. 创建 trigger 为 `.scheduled` 的普通 `AgentRun`。
4. Runtime 调用已登记的只读 Source Tools。
5. 产出 `AgentArtifact(type: .markdown)`，并持久化运行记录、来源和成本。
6. 成功后发送本地通知，点击打开对应 Run / Artifact。

本地 Markdown 文件可导出，但自动发布到 GitHub、社交平台或其他外部系统不在定时任务的默认权限内。

### 5.7 用户配置

用户可配置：

- 是否启用、执行周期和“立即运行”；
- 关注主题、数据源、语言和最大采集数量；
- Agent Runtime 与 AI Provider；
- 单次最大步数、Token 或费用预算；
- 网络和能源条件；
- 生成后是否通知；
- Artifact 保留周期。

无人值守运行默认只允许只读 Tool。发布、评论、修改仓库、修改用户数据等写操作不能因“定时任务已启用”而自动获得授权。

### 5.8 长期验收标准

- 同一计划周期不会重复创建 Run；
- App 长时间未运行后只补跑一次，不补齐全部历史周期；
- Provider 不可用、网络失败和预算不足均有可审计结果；
- 禁用 Automation 后不再注册后续运行；
- 每次运行均产生可追溯 AgentRun 和 Markdown Artifact；
- 用户可以查看历史、立即重跑、导出和删除产物；
- 定时运行不能绕过 Tool allowlist、Approval 与外部写入限制。

工期粗估：Automation 调度、持久化、设置和 AgentRun 集成约 2～3 周；首批多数据源标准化约再增加 2～4 周，实际范围以数据源数量和授权要求为准。

---

## 六、从短期到长期的演进

```text
S0：fork 上游，跑通 Actions + GitHub Pages
  ↓
S1：Starcat 直读 Manifest + Markdown，提供公共 AI Radar
  ↓
S2：增加 manifest-v1.json、checksum 和稳定分类元数据
  ↓
L1：建设通用 Agent Automation / Scheduler
  ↓
L2：建设结构化只读 Source Tools
  ↓
L3：Agent 工作台上线“我的雷达”
```

长期上线后，公共雷达仍应保留：

| 维度 | 公共雷达 | 我的雷达 |
|---|---|---|
| 生成位置 | GitHub Actions | 用户 Mac |
| 内容 | 所有用户相同 | 用户个性化 |
| App 关闭后生成 | 可以 | 不保证 |
| AI 成本 | Starcat 承担 | 用户 BYOK |
| 运行审计 | 中央 Workflow 日志 | 本地 AgentRun / Trace |
| 产品位置 | 探索 | Agent 工作台 |

当本地定时任务未启用、因环境未执行或 Provider 失败时，公共雷达仍是稳定的默认内容。

---

## 七、实施前需要确认的决策

下列推荐值已用于本文方案描述，但实际修改代码、创建 fork、配置 Secrets 或部署 Pages 前仍需要 dong4j 明确授权：

1. 公共内容仓库是否使用 `starcat-app/agents-radar`，本地映射为 `supports/starcat-agents-radar/`。
2. 首发是否直接使用 GitHub Pages，待稳定后再映射 `radar.starcat.ink`。
3. Starcat 入口是否固定为「探索 → AI Radar」，而不是 Agent 工作台。
4. 快速验证是否先兼容现有 `manifest.json`，稳定后再增加 `manifest-v1.json`。
5. 首批保留哪些 report ID，以及中英文缺失时的产品回退语义。

本文不构成代码、数据库、分支、fork、GitHub Actions、Secrets、Pages 或部署操作授权。
