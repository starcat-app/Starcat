# Starcat AnySearch REST API 集成方案

> 目标：在 Starcat 中通过 AnySearch REST API 引入网络搜索能力，并将其同时用于 **AI 摘要生成的 Context Provider** 和 **Starcat 搜索入口的外部搜索数据源**。
>
> 当前版本：v1.0
>
> 适用范围：Starcat macOS App、Starcat 后端服务、AI 摘要生成链路、搜索入口。

---

## 1. 背景

Starcat 当前已经具备本地数据搜索能力，主要搜索对象包括：

- 本地已缓存的 GitHub Repo 信息；
- README 内容；
- Starcat 本地数据库中的关键词索引；
- 后续可能包含本地全文搜索索引、AI 分析结果、收藏、历史记录等。

但是当前搜索能力仍然偏 **本地、静态、已收录数据**，存在几个明显限制：

1. **无法发现未进入 Starcat 本地库的新项目**；
2. **无法搜索网络上的项目讨论、教程、文档、新闻、竞品对比**；
3. **AI 摘要生成时上下文不足**，目前主要依赖 GitHub metadata、README、topics、releases、stars 等信息；
4. **对 GitHub Repo 的外部认知较弱**，例如 Hacker News 讨论、官方文档、博客文章、用户评价等信息无法自然进入摘要上下文。

因此，引入 AnySearch 的核心目的不是替代 Starcat 本地搜索，而是补充一个 **网络搜索层**：

```text
Starcat Search = Local Search + AnySearch Web Search
Starcat AI Summary Context = GitHub Context + Local Repo Context + External Web Context
```

AnySearch 官方提供 REST API、MCP、Skill 等接入方式。本方案明确选择 **REST API**，不使用 MCP / Skill 作为 Starcat 内部集成方式。

---

## 2. AnySearch 能力边界

根据 AnySearch 官方文档，它提供统一搜索 API，API Base URL 为：

```text
https://api.anysearch.com
```

核心接口：

```http
POST /v1/search
```

官方文档显示该接口支持匿名访问和 API Key 鉴权：

- 匿名访问：不传 `Authorization`，按客户端 IP 进行免费额度和限流；
- 鉴权访问：传 `Authorization: Bearer YOUR_ANYSEARCH_API_KEY`，使用更高额度和并发限制；
- 如果传了无效、禁用或过期的 API Key，网关会返回 `401 Unauthorized` 或 `403 Forbidden`，不会自动降级为匿名访问。

参考资料：

- AnySearch API Reference: https://www.anysearch.com/docs
- AnySearch Home: https://www.anysearch.com/
- AnySearch MCP Server: https://github.com/anysearch-ai/anysearch-mcp-server
- AnySearch Skill: https://github.com/anysearch-ai/anysearch-skill

### 2.1 请求参数

AnySearch `/v1/search` 主要参数如下：

| 参数 | 类型 | 说明 | Starcat 建议 |
|---|---:|---|---|
| `query` | string | 搜索关键词 | 必填 |
| `max_results` | int | 返回结果数量，默认 10，范围 1-100 | 搜索入口建议 10-20；AI Context 建议 5-10 |
| `domain` | string | 领域过滤，例如 `code` | Repo/开发类搜索建议使用 `code` |
| `tag` | string | 子领域标签，例如 `code.doc` | 文档类搜索可用 |
| `content_types` | string[] | 内容类型过滤，例如 `web`、`news`、`doc` | 搜索入口可开放，AI Context 默认 web/doc/news |
| `zone` | string | 区域，例如 `cn` / `intl` | 可根据用户设置或系统语言选择 |
| `language` | string | 语言偏好，例如 `zh-CN`、`en` | 默认跟随 App 语言 |
| `params` | object | 扩展参数 | v1 可预留，不强依赖 |

### 2.2 响应结构

官方示例返回结构大致如下：

```json
{
  "code": 0,
  "message": "success",
  "data": {
    "results": [
      {
        "title": "Go 1.22 Release Notes",
        "url": "https://go.dev/doc/go1.22",
        "snippet": "Go 1.22 is a major release...",
        "content": "Detailed content here..."
      }
    ],
    "metadata": {
      "request_id": "req_abc123",
      "total_results": 1,
      "search_time_ms": 342
    }
  }
}
```

Starcat 内部不应该直接把 AnySearch 原始响应透传到 UI 或 LLM，而应该做一次统一抽象。

---

## 3. 集成定位

AnySearch 在 Starcat 中有两个明确落点。

### 3.1 落点一：AI 摘要生成时的 Context Provider

用于在生成 Repo AI 摘要时，补充外部网络上下文。

典型场景：

- 查询项目官网、文档、教程；
- 查询项目是否被 Hacker News / Product Hunt / 博客讨论；
- 查询竞品和替代方案；
- 查询近期发布动态；
- 查询该项目在外部语境中的定位。

它产出的不是最终答案，而是供 LLM 使用的上下文片段。

```text
AnySearchContextProvider
        ↓
ExternalSearchContext
        ↓
AIContextAggregator
        ↓
LLM Summary Prompt
```

### 3.2 落点二：Starcat 搜索入口的网络搜索数据源

用于增强 Starcat 搜索页。

当前搜索主要来自本地数据，后续搜索页可以拆成：

```text
Search Sources:
- Local Repos
- Local README / Full-text Index
- GitHub Trending / Activity Cache
- AnySearch Web Results
```

用户在 Starcat 搜索框输入关键词时，Starcat 可以同时返回：

1. 本地已收藏 / 已缓存 Repo；
2. 本地 README / AI Summary 命中的结果；
3. AnySearch 网络搜索结果；
4. 可选的 GitHub 全站搜索结果。

AnySearch 搜索结果用于“发现外部信息”，不是本地索引的替代品。

---

## 4. 总体架构

推荐将 AnySearch 封装为独立模块，不直接散落在 ViewModel 或 AI 生成逻辑里。

```text
┌──────────────────────────────────────────────────────────────┐
│                         Starcat UI                           │
│                                                              │
│  Repo Detail / AI Summary       Search Page                  │
│           │                         │                        │
└───────────┼─────────────────────────┼────────────────────────┘
            │                         │
            ▼                         ▼
┌──────────────────────┐   ┌────────────────────────────┐
│ AIContextAggregator  │   │ SearchCoordinator           │
└──────────┬───────────┘   └──────────────┬─────────────┘
           │                              │
           ▼                              ▼
┌──────────────────────┐   ┌────────────────────────────┐
│ AnySearchContext     │   │ AnySearchSearchProvider     │
│ Provider             │   │                            │
└──────────┬───────────┘   └──────────────┬─────────────┘
           │                              │
           └──────────────┬───────────────┘
                          ▼
              ┌──────────────────────┐
              │ AnySearchClient       │
              │ REST API Adapter      │
              └──────────┬───────────┘
                         ▼
              ┌──────────────────────┐
              │ AnySearch REST API    │
              │ POST /v1/search       │
              └──────────────────────┘
```

---

## 5. 模块设计

### 5.1 AnySearchClient

职责：

- 负责 REST API 调用；
- 处理 API Key；
- 处理 HTTP 状态码；
- 处理超时、重试、限流；
- 解析 AnySearch 原始响应；
- 输出 Starcat 内部统一模型。

建议接口：

```swift
protocol AnySearchClientProtocol {
    func search(_ request: AnySearchRequest) async throws -> AnySearchResponse
}
```

内部模型：

```swift
struct AnySearchRequest: Codable, Hashable {
    let query: String
    let maxResults: Int
    let domain: String?
    let tag: String?
    let contentTypes: [String]?
    let zone: String?
    let language: String?
    let params: [String: String]?
}

struct AnySearchResponse: Codable {
    let results: [AnySearchResult]
    let metadata: AnySearchMetadata?
}

struct AnySearchResult: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
    let snippet: String?
    let content: String?
    let sourceDomain: String?
}

struct AnySearchMetadata: Codable {
    let requestId: String?
    let totalResults: Int?
    let searchTimeMs: Int?
}
```

`id` 建议使用：

```text
sha256(url + title)
```

避免 API 没有稳定 ID 时影响缓存和列表 diff。

---

### 5.2 AnySearchContextProvider

职责：

- 在 Repo AI 摘要生成时，根据 repo 信息生成多组搜索 query；
- 调用 AnySearch；
- 对搜索结果做去重、过滤、排序；
- 输出 LLM-friendly Markdown Context；
- 控制 token 数量，避免把过长网页内容全部塞入 prompt。

建议接口：

```swift
protocol AIContextProvider {
    var id: String { get }
    var name: String { get }
    func collect(repo: Repo) async throws -> AIContextChunk
}

final class AnySearchContextProvider: AIContextProvider {
    let id = "anysearch"
    let name = "AnySearch External Context"
}
```

### 5.3 AnySearchSearchProvider

职责：

- 接入 Starcat 搜索入口；
- 接收用户搜索关键词；
- 返回可展示的网络搜索结果；
- 与本地搜索结果并行执行；
- 支持取消、分页、刷新、错误降级。

建议接口：

```swift
protocol SearchProvider {
    var id: String { get }
    var name: String { get }
    func search(_ query: SearchQuery) async throws -> SearchProviderResult
}

final class AnySearchSearchProvider: SearchProvider {
    let id = "anysearch-web"
    let name = "Web"
}
```

---

## 6. AI Context Provider 详细方案

### 6.1 触发时机

AnySearch 不建议在 Repo 列表页自动触发，成本高、网络噪音大。

推荐触发时机：

| 场景 | 是否触发 | 说明 |
|---|---:|---|
| Repo 列表滚动 | 否 | 避免大量无意义请求 |
| Repo 详情页打开 | 默认否 | 可展示“增强分析”按钮 |
| 用户点击 AI 摘要 | 是 | 作为摘要上下文的一部分 |
| 用户点击刷新 AI 摘要 | 是 | 可强制刷新外部上下文 |
| 后台批量分析 | 可选 | 需要严格限流 |

推荐默认策略：

```text
只有在用户主动触发 AI 分析时，才调用 AnySearchContextProvider。
```

### 6.2 Query 生成策略

基于 repo 信息生成多个 query。

输入：

```text
owner: anthropics
repo: claude-code
fullName: anthropics/claude-code
homepage: optional
primaryLanguage: TypeScript
stars: xxx
readmeSummary: optional
```

建议 query 模板：

```text
"{owner}/{repo}" GitHub
"{repo}" documentation
"{repo}" tutorial
"{repo}" alternative
"{repo}" Hacker News
"{repo}" architecture
"{repo}" release notes
```

如果 repo 有 homepage：

```text
site:{homepageDomain} "{repo}"
```

如果 repo 是 AI / Agent / MCP / RAG 相关项目：

```text
"{repo}" AI agent
"{repo}" MCP
"{repo}" RAG
```

### 6.3 Query 数量控制

为了控制成本和延迟，v1 建议：

```text
每个 repo 最多 3 组 query
每组 max_results = 5
总候选结果最多 15 条
过滤后最多保留 5-8 条进入 LLM Context
```

推荐默认组合：

1. `"{owner}/{repo}" GitHub`；
2. `"{repo}" documentation tutorial`；
3. `"{repo}" alternative review Hacker News`。

### 6.4 结果过滤

需要过滤掉低质量结果：

- URL 为空；
- title 为空；
- 明显广告页；
- 重复 URL；
- 与 repo 名称完全无关；
- 内容过短；
- 纯聚合垃圾页；
- 明显 SEO 站点。

推荐评分模型：

```text
score = titleMatchScore
      + urlMatchScore
      + domainTrustScore
      + contentLengthScore
      + sourceTypeScore
      - spamPenalty
```

高优先级来源：

| 来源 | 权重 |
|---|---:|
| 官方文档 | 高 |
| GitHub / GitLab | 高 |
| Hacker News | 高 |
| Product Hunt | 中高 |
| 技术博客 | 中 |
| Medium / Dev.to | 中 |
| 低质量 SEO 聚合页 | 低 |

### 6.5 Context 输出格式

AnySearchContextProvider 最终输出 Markdown，不直接输出 JSON。

建议格式：

```markdown
# External Web Context

Source: AnySearch
Generated At: 2026-06-12T10:00:00Z
Repo: owner/repo

## Summary

The following external sources may help understand the repository beyond GitHub README and metadata.

## Search Results

### 1. {title}

URL: {url}
Source Domain: {domain}
Relevance: {score}

Snippet:
{snippet}

Content Excerpt:
{content excerpt, max 800 chars}

---

### 2. {title}
...
```

### 6.6 Token 控制

建议规则：

| 字段 | 最大长度 |
|---|---:|
| title | 160 chars |
| snippet | 500 chars |
| content excerpt | 800-1200 chars |
| 单条结果总长度 | 1500 chars |
| 单个 repo 外部上下文总长度 | 6000-10000 chars |

LLM Prompt 中可以这样注入：

```markdown
## External Context

The following content is from web search results. It may contain outdated or noisy information. Use it only as supplementary context and prefer official repository data when conflicts exist.

{anysearch_context}
```

### 6.7 与其他 Context Provider 的关系

推荐 Context 优先级：

| 优先级 | Provider | 说明 |
|---:|---|---|
| P0 | GitHubMetadataContextProvider | repo 基础信息，稳定可靠 |
| P0 | ReadmeContextProvider | 项目官方自述，摘要核心来源 |
| P0 | RepomixContextProvider | 本地源码上下文，代码分析核心来源 |
| P1 | CodeGraphContextProvider | 结构、调用关系、模块分析 |
| P1 | AnySearchContextProvider | 外部搜索上下文，补充材料 |
| P2 | DeepWiki / ZRead / CodeWiki LinkProvider | 已索引文档站跳转 |

AnySearch 的定位：

```text
辅助判断项目外部影响力、使用场景、讨论热度、文档生态、竞品关系。
```

不应该让 AnySearch 覆盖 README / 源码分析结论。

---

## 7. Starcat 搜索入口详细方案

### 7.1 搜索入口目标

当前 Starcat 搜索偏本地，AnySearch 引入后，搜索页需要从“本地检索”升级为“多数据源聚合检索”。

目标：

```text
用户输入一个关键词，可以同时看到本地结果和网络结果。
```

例如搜索：

```text
mcp server go
```

返回：

- 本地已收藏 repo；
- 本地 README 命中的 repo；
- 本地 AI 摘要命中的 repo；
- AnySearch 网络搜索结果；
- 后续可选 GitHub Search 结果。

### 7.2 UI 展示建议

搜索页建议分区展示，而不是把本地和网络结果混在一个列表里。

```text
Search Results

Local
- Repo A
- Repo B
- README match C

Web
- Result from AnySearch 1
- Result from AnySearch 2
- Result from AnySearch 3

GitHub
- Repo from GitHub Search 1
- Repo from GitHub Search 2
```

或者使用 Tab：

```text
All | Local | Repos | README | Web | GitHub
```

v1 推荐：

```text
本地结果优先，网络结果单独分区展示。
```

原因：

1. 本地结果响应更快；
2. 网络结果质量不稳定；
3. 用户更容易理解数据来源；
4. 避免 AnySearch 结果挤掉本地收藏项目。

### 7.3 搜索执行策略

推荐并行执行：

```swift
async let localResults = localSearchProvider.search(query)
async let webResults = anySearchSearchProvider.search(query)

let results = await SearchResultGroup(
    local: localResults,
    web: webResults
)
```

体验策略：

1. 本地结果先展示；
2. AnySearch 结果加载中显示 skeleton 或 loading；
3. AnySearch 失败时不影响本地结果；
4. 用户继续输入时取消上一次 AnySearch 请求；
5. 输入防抖，建议 400-600ms；
6. query 少于 2 个字符不触发网络搜索。

### 7.4 搜索结果模型

统一抽象：

```swift
struct SearchResultGroup {
    let query: String
    let localResults: [SearchResultItem]
    let webResults: [SearchResultItem]
    let githubResults: [SearchResultItem]
}

enum SearchResultItem {
    case repo(RepoSearchResult)
    case readme(ReadmeSearchResult)
    case web(WebSearchResult)
    case github(GitHubRepoSearchResult)
}

struct WebSearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
    let snippet: String?
    let source: String
    let sourceDomain: String?
    let contentPreview: String?
}
```

AnySearch 结果映射为：

```text
AnySearchResult -> WebSearchResult
```

### 7.5 搜索结果操作

AnySearch 网络结果可以支持：

- 打开网页；
- 复制链接；
- 使用该结果生成 AI 摘要；
- 保存到 Starcat 本地；
- 关联到某个 Repo；
- 对该网页进行进一步 AI 分析。

后续可以扩展：

```text
Web Result → Save as External Reference → Repo Detail References
```

这样 Starcat 可以沉淀外部资料，而不是每次都重新搜索。

---

## 8. 设置页设计

建议在 Starcat 设置中新增：

```text
Settings → Integrations → AnySearch
```

配置项：

| 配置 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| Enable AnySearch | Bool | false | 总开关 |
| API Key | Secure String | empty | 存 Keychain |
| Use Anonymous Mode | Bool | true | 未配置 API Key 时允许匿名访问 |
| Enable in AI Summary | Bool | true | AI 摘要上下文开关 |
| Enable in Search | Bool | true | 搜索入口开关 |
| Max Results for Search | Int | 10 | 搜索页返回数量 |
| Max Results for AI Context | Int | 5 | AI 上下文结果数量 |
| Language | Enum | Auto | 跟随系统 / 中文 / 英文 |
| Zone | Enum | Auto | intl / cn / auto |
| Cache TTL | Enum | 1d / 7d / 30d | 搜索缓存有效期 |

API Key 必须存储到 macOS Keychain，不建议明文写入数据库。

### 8.1 API Key 策略

推荐：

```text
用户自填 AnySearch API Key。
```

不推荐：

```text
Starcat 客户端内置开发者 API Key。
```

原因：

1. macOS 客户端无法可靠隐藏 API Key；
2. 容易被提取和滥用；
3. 成本不可控；
4. 用户额度和开发者额度难以隔离。

如果未来 Starcat 有服务端，可以增加：

```text
Starcat Cloud Proxy → AnySearch API
```

由服务端统一做鉴权、限流、缓存和成本控制。

---

## 9. 缓存设计

AnySearch 结果应该缓存，避免重复请求。

### 9.1 缓存对象

建议新增表：

```sql
CREATE TABLE anysearch_cache (
    id TEXT PRIMARY KEY,
    query TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    response_json TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'anysearch',
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    expires_at DATETIME NOT NULL
);

CREATE UNIQUE INDEX idx_anysearch_cache_request_hash
ON anysearch_cache(request_hash);

CREATE INDEX idx_anysearch_cache_query
ON anysearch_cache(query);
```

`request_hash` 由以下字段生成：

```text
sha256(query + max_results + domain + tag + content_types + zone + language)
```

### 9.2 TTL 建议

| 场景 | TTL |
|---|---:|
| 搜索入口普通 query | 1 天 |
| Repo AI 摘要外部上下文 | 7 天 |
| 手动刷新 | 直接绕过缓存 |
| 失败结果 | 5-15 分钟 |
| 401 / 403 | 不缓存或短缓存 |
| 429 | 5-30 分钟 |

### 9.3 缓存命中策略

```text
1. 计算 request_hash
2. 查询 anysearch_cache
3. 如果未过期，直接返回
4. 如果过期，发起网络请求
5. 请求成功后更新缓存
6. 请求失败时，如果存在旧缓存，可返回 stale cache 并标记 stale=true
```

---

## 10. 限流与并发控制

AnySearch 用在两个地方后，必须避免请求泛滥。

### 10.1 搜索入口限流

建议：

```text
debounce: 400-600ms
minimum query length: 2 chars
max concurrent web search: 1
new query cancels previous query
same query within 30s returns memory cache
```

### 10.2 AI 摘要限流

建议：

```text
single repo summary: max 3 AnySearch requests
batch summary: max 1-2 concurrent repos
background task: rate limit queue
retry: only retry network timeout / 5xx
```

### 10.3 错误降级

| 错误 | 处理 |
|---|---|
| 401 / 403 | 提示 API Key 无效，关闭本次 AnySearch 调用 |
| 429 | 提示额度或频率受限，使用缓存或跳过 |
| 5xx | 自动重试 1 次，仍失败则跳过 |
| Timeout | AI 摘要跳过外部上下文，搜索页展示失败状态 |
| JSON Decode Error | 记录日志，不影响主流程 |

---

## 11. 网络与安全

### 11.1 macOS App 网络权限

Starcat 上架 Mac App Store 时，需要确保网络请求符合 App Sandbox 能力配置。

通常需要：

```text
com.apple.security.network.client = true
```

如果未来通过本地代理或服务端代理，也需要对应调整。

### 11.2 API Key 安全

要求：

- API Key 存储在 Keychain；
- 日志中不能打印 API Key；
- crash report 中不能包含 Authorization Header；
- 网络调试开关默认关闭；
- 401 / 403 时不要把完整请求头展示给用户。

### 11.3 用户隐私

搜索 query 可能包含用户输入、repo 名称、项目描述等信息。

建议在设置页说明：

```text
启用 AnySearch 后，Starcat 会将搜索关键词或仓库相关查询发送到 AnySearch，用于获取网络搜索结果。
```

对于私有 repo：

```text
默认不对 private repo 使用 AnySearch。
```

除非用户明确开启：

```text
Enable AnySearch for Private Repositories
```

默认值必须为 false。

---

## 12. Prompt 集成策略

AI 摘要生成时，AnySearch 只能作为补充上下文。

推荐 Prompt 约束：

```markdown
You are analyzing a GitHub repository.

Use the repository README, metadata, source context, and external web context.

Priority rules:
1. Prefer official repository data over external web content.
2. Use AnySearch results only as supplementary context.
3. If external sources conflict with README or source code, mention uncertainty.
4. Do not invent facts that are not supported by context.
5. When external context is weak or noisy, ignore it.
```

### 12.1 外部上下文区块

```markdown
## External Web Context from AnySearch

The following search results were retrieved from the web. They may be incomplete, outdated, or noisy.

{anysearch_context}
```

### 12.2 适合增强的摘要维度

AnySearch 可以帮助 AI 摘要补强这些部分：

| 摘要维度 | 是否适合 AnySearch |
|---|---:|
| 项目定位 | 适合 |
| 使用场景 | 适合 |
| 外部讨论 | 适合 |
| 替代方案 | 适合 |
| 教程和文档 | 适合 |
| 代码架构 | 不适合作为主来源 |
| API 细节 | 不适合作为主来源 |
| 安全结论 | 需要谨慎 |

---

## 13. 数据流设计

### 13.1 AI 摘要链路

```text
User clicks "Generate AI Summary"
        ↓
Load GitHub metadata
        ↓
Load README cache / fetch README
        ↓
Optional: Load Repomix context
        ↓
Optional: Load CodeGraphContext output
        ↓
If enabled: AnySearchContextProvider.collect(repo)
        ↓
Aggregate context
        ↓
Trim / rank / compress context
        ↓
Call LLM
        ↓
Save summary to local database
```

### 13.2 搜索入口链路

```text
User types query
        ↓
Debounce
        ↓
SearchCoordinator.search(query)
        ↓
Run LocalSearchProvider immediately
        ↓
Run AnySearchSearchProvider if enabled
        ↓
Merge grouped results
        ↓
UI updates local results first
        ↓
UI appends web results when ready
```

---

## 14. 数据库建议

### 14.1 AnySearch 配置表

如果配置不全部放 UserDefaults，可以建表：

```sql
CREATE TABLE integration_settings (
    id TEXT PRIMARY KEY,
    enabled INTEGER NOT NULL,
    config_json TEXT,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

`anysearch` 配置：

```json
{
  "enableInSearch": true,
  "enableInAISummary": true,
  "useAnonymousMode": true,
  "maxResultsForSearch": 10,
  "maxResultsForAIContext": 5,
  "language": "auto",
  "zone": "auto",
  "cacheTTL": "7d"
}
```

API Key 不放这里，放 Keychain。

### 14.2 Web Search History

如果需要保存搜索历史：

```sql
CREATE TABLE web_search_history (
    id TEXT PRIMARY KEY,
    query TEXT NOT NULL,
    provider TEXT NOT NULL,
    result_count INTEGER NOT NULL,
    created_at DATETIME NOT NULL
);
```

### 14.3 Repo External References

后续可把 AnySearch 结果沉淀为 Repo 外部资料：

```sql
CREATE TABLE repo_external_references (
    id TEXT PRIMARY KEY,
    repo_id TEXT NOT NULL,
    title TEXT NOT NULL,
    url TEXT NOT NULL,
    snippet TEXT,
    source_provider TEXT NOT NULL,
    source_domain TEXT,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    UNIQUE(repo_id, url)
);
```

---

## 15. 实现步骤

### Phase 1：基础 REST Client

目标：先打通 AnySearch REST API。

任务：

- 新增 `AnySearchClient`；
- 新增请求 / 响应模型；
- 支持 API Key 和匿名模式；
- 支持 timeout；
- 支持基础错误处理；
- 新增设置页配置；
- API Key 存 Keychain。

验收标准：

```text
在调试页面输入 query，可以看到 AnySearch 原始搜索结果。
```

---

### Phase 2：接入 Starcat 搜索入口

目标：让搜索页出现 Web 分区。

任务：

- 新增 `AnySearchSearchProvider`；
- 接入 `SearchCoordinator`；
- 搜索页增加 Web Section；
- 本地结果和 Web 结果并行加载；
- 支持取消请求；
- 支持错误提示和空状态；
- 增加缓存。

验收标准：

```text
搜索关键词时，本地结果立即展示，AnySearch 网络结果随后展示；AnySearch 失败不影响本地搜索。
```

---

### Phase 3：接入 AI 摘要 Context Provider

目标：让 AI 摘要使用 AnySearch 外部上下文。

任务：

- 新增 `AnySearchContextProvider`；
- 设计 repo query templates；
- 结果去重、评分和过滤；
- 输出 Markdown Context；
- 接入 `AIContextAggregator`；
- Prompt 增加外部上下文使用规则；
- 增加 token 控制。

验收标准：

```text
生成 AI 摘要时，可以看到摘要内容中合理引用外部资料信息，但不会被低质量搜索结果误导。
```

---

### Phase 4：体验增强

目标：让 AnySearch 成为 Starcat 的长期能力。

任务：

- Repo 详情页增加 External References；
- 用户可保存某个 Web Result 到 Repo；
- AI 摘要中展示使用了哪些外部来源；
- 支持手动刷新外部上下文；
- 支持 private repo 安全开关；
- 搜索页支持 `Web` Tab；
- 支持按 `docs`、`news`、`code` 等类型过滤。

---

## 16. 关键代码示例

### 16.1 请求示例

```swift
let request = AnySearchRequest(
    query: "mcp server go github",
    maxResults: 10,
    domain: "code",
    tag: nil,
    contentTypes: ["web", "doc"],
    zone: "intl",
    language: "en",
    params: nil
)

let response = try await anySearchClient.search(request)
```

### 16.2 HTTP 调用示例

```swift
final class AnySearchClient: AnySearchClientProtocol {
    private let baseURL = URL(string: "https://api.anysearch.com")!
    private let urlSession: URLSession
    private let apiKeyProvider: AnySearchAPIKeyProvider

    init(
        urlSession: URLSession = .shared,
        apiKeyProvider: AnySearchAPIKeyProvider
    ) {
        self.urlSession = urlSession
        self.apiKeyProvider = apiKeyProvider
    }

    func search(_ request: AnySearchRequest) async throws -> AnySearchResponse {
        let url = baseURL.appendingPathComponent("/v1/search")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = try apiKeyProvider.loadAPIKey(), !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await urlSession.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnySearchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try AnySearchResponseParser.parse(data)
        case 401, 403:
            throw AnySearchError.unauthorized
        case 429:
            throw AnySearchError.rateLimited
        case 500...599:
            throw AnySearchError.serverError(httpResponse.statusCode)
        default:
            throw AnySearchError.httpError(httpResponse.statusCode)
        }
    }
}
```

### 16.3 Context Provider 示例

```swift
final class AnySearchContextProvider: AIContextProvider {
    let id = "anysearch"
    let name = "AnySearch External Context"

    private let client: AnySearchClientProtocol
    private let ranker: AnySearchResultRanker

    init(client: AnySearchClientProtocol, ranker: AnySearchResultRanker) {
        self.client = client
        self.ranker = ranker
    }

    func collect(repo: Repo) async throws -> AIContextChunk {
        let queries = AnySearchRepoQueryBuilder.buildQueries(repo: repo)
        var allResults: [AnySearchResult] = []

        for query in queries.prefix(3) {
            let response = try await client.search(
                AnySearchRequest(
                    query: query,
                    maxResults: 5,
                    domain: "code",
                    tag: nil,
                    contentTypes: ["web", "doc", "news"],
                    zone: nil,
                    language: nil,
                    params: nil
                )
            )
            allResults.append(contentsOf: response.results)
        }

        let ranked = ranker.rankAndFilter(allResults, repo: repo)
        let markdown = AnySearchContextRenderer.render(ranked.prefix(8), repo: repo)

        return AIContextChunk(
            providerId: id,
            title: "External Web Context",
            content: markdown,
            priority: .supplementary
        )
    }
}
```

---

## 17. 风险与注意事项

### 17.1 AnySearch 是外部 SaaS

AnySearch REST API 依赖外部服务，不应成为 Starcat 核心功能的硬依赖。

处理策略：

```text
AnySearch 失败时，AI 摘要仍然可以使用 README / GitHub metadata / Repomix / CodeGraphContext 继续生成。
```

### 17.2 搜索结果质量不可控

网络搜索结果可能存在：

- 过期；
- SEO 垃圾；
- 与 repo 同名但无关；
- 非官方内容；
- 内容片段不完整。

处理策略：

```text
搜索结果必须经过过滤、评分、去重，并在 Prompt 中声明其仅为补充上下文。
```

### 17.3 成本与额度风险

AnySearch 支持匿名访问，但匿名模式有 IP 级免费额度和限流；生产环境建议用户配置 API Key。

处理策略：

```text
Settings 中默认关闭 AnySearch 或提示用户配置 API Key。
```

### 17.4 私有仓库隐私风险

私有 repo 名称、描述、README 摘要不应默认发送到外部搜索服务。

处理策略：

```text
private repo 默认禁用 AnySearch Context Provider。
```

---

## 18. 推荐默认配置

```json
{
  "anysearch": {
    "enabled": false,
    "useAnonymousMode": true,
    "enableInSearch": true,
    "enableInAISummary": true,
    "enableForPrivateRepos": false,
    "maxResultsForSearch": 10,
    "maxResultsForAIContext": 5,
    "searchDebounceMs": 500,
    "timeoutSeconds": 15,
    "cacheTTLForSearchHours": 24,
    "cacheTTLForAIContextDays": 7
  }
}
```

是否默认开启 AnySearch，有两种选择：

### 方案 A：默认关闭

优点：

- 更稳妥；
- 更符合隐私预期；
- 不会产生额外网络请求；
- 更适合早期上架。

缺点：

- 用户需要主动开启。

### 方案 B：默认开启匿名搜索

优点：

- 用户一开始就能体验 Web Search；
- 搜索体验更强。

缺点：

- 可能触发额度问题；
- 隐私说明必须更明显；
- 上架审核时需要解释网络请求用途。

推荐：

```text
v1 默认关闭，在首次使用 Web Search / AI 外部增强时引导用户开启。
```

---

## 19. 最终结论

AnySearch 在 Starcat 中应该被定位为：

```text
External Web Search Provider + AI External Context Provider
```

它的价值主要体现在两个方面：

1. **增强 AI 摘要上下文**：让 Repo 摘要不仅依赖 README 和 GitHub metadata，还能参考官方文档、教程、讨论、竞品和外部资料；
2. **增强 Starcat 搜索入口**：让 Starcat 搜索从本地搜索扩展为“本地 + 网络”的组合搜索体验。

但它不应该被定位为：

```text
Repo 代码分析引擎
源码上下文生成器
CodeGraph 替代品
Repomix 替代品
```

推荐最终架构：

```text
AI 摘要：
GitHub Metadata + README + Repomix + CodeGraphContext + AnySearch External Context

搜索入口：
Local Search + Full-text Search + AnySearch Web Search + GitHub Search
```

落地顺序：

```text
Phase 1: AnySearch REST Client
Phase 2: 搜索入口 Web Section
Phase 3: AI Summary Context Provider
Phase 4: External References 沉淀与体验增强
```

这条路线能让 AnySearch 以低耦合方式接入 Starcat，同时不会破坏现有本地搜索和 AI 摘要链路。
