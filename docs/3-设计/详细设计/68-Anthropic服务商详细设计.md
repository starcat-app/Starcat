# 68 — Anthropic Messages API 服务商详细设计

> 日期：2026-09-13
> 状态：适配器已接入代码；2026-11-12 核对工厂分流与 Embedding 边界，原实施步骤保留作设计记录
> 适用版本：dev 后续功能迭代（不改已发布 schema）
> 关联：`15-AI设置与调用链重构方案.md`、`65-AgentRuntime与AI服务统一路由方案.md`、`69-CC-Switch导入Provider详细设计.md`

---

## 1. 原问题与当前实现

2026-09-13 制定方案时，远端 AI 主要走 OpenAI Chat Completions。当前 `AIClientFactory.make` 已把 `.anthropic` 路由到 `AnthropicClient`，`.localAI` 路由到 `LocalMLXClient`，其余类型走 `OpenAIClient`，不能再按“Anthropic 未接入”设计调用链。

原问题是把 Anthropic Messages 端点当成 OpenAI Chat Completions 使用。当前必须选择与端点协议匹配的 Provider 类型；已有适配器不等于所有中转端点均已验证。

目标：在不改摘要 / Chat / RAG / Agent 业务消息模型的前提下，增加一条 Anthropic Messages adapter，让设置页能新增「Anthropic」类型的 Provider，通过连接测试后进入正式列表。

源码入口：`Starcat/Features/AI/AIClient.swift`、`Starcat/Features/AI/Anthropic/`、`Starcat/Core/Settings/AppSettings.swift`。`supportsEmbeddingEndpoint` 已排除 `.anthropic`，其 `embedding` 方法也明确拒绝调用。下面的原始任务拆分与测试矩阵不作为本次真实 Provider 联调或人工验收通过的证明；65 号统一路由方案的待实施范围不因本适配器存在而自动完成。

## 2. 已冻结决策

| 项 | 决策 |
|---|---|
| 协议 | Anthropic Messages API（`POST /v1/messages`），不是 OpenAI 兼容层 |
| SDK | 不新增 SPM。用 `URLSession` 自研最小客户端，避免 MacPaw/OpenAI 误打 Completions |
| 业务层 | 继续只认 `AIClientProtocol` / `AIChatRequest` / `AIChatResponse` / `AIChatStreamEvent` |
| Agent | `LoopAgentRuntime` / `AgentLoopModelClient` 不改消息模型；tool_use 转换只发生在 adapter 内 |
| Embedding | `supportsEmbeddingEndpoint = false`。语义搜索 / RAG 向量化必须用其他 Provider |
| 枚举位置 | `AIServiceProvider.anthropic` 追加在 `localAI` **之后**，不改已有 rawValue |
| 图标 | 复用已有 `claudecode` imageset（Claude Spark），不新增品牌资源 |
| JSON 输出 | `.jsonObject` 用强制 tool `starcat_json_result` 收取，再把 arguments 填回 `content`，业务层无感 |
| 思考链 | `disableThinking == true` 时不传 `thinking`；否则不主动打开 extended thinking（避免无预算乱扣） |
| 鉴权 | 同时发 `x-api-key` 与 `Authorization: Bearer`，兼容官方与多数中转 |
| API 版本头 | `anthropic-version: 2023-06-01` |

## 3. 明确不做

- 不改 `OpenAIClient` 去猜 Anthropic URL。
- 不把 Anthropic 伪装成 OpenAI Compatible 选项。
- 不做 Anthropic Embeddings、Batches、Files、Admin API。
- 不把 Claude Code CLI / `claudeCLI` RAG 后端改成这条 HTTP adapter（那是本机 CLI 登录态，见文档 65）。
- 不在本方案做 CC Switch 导入（见文档 69）。
- 不新增数据库 migration。Profile 仍走 UserDefaults JSON，Key 仍走 Keychain。

## 4. 当前实现锚点

| 锚点 | 文件 | 实现位置或约束 |
|---|---|---|
| 工厂 | `Starcat/Features/AI/AIClient.swift` `AIClientFactory.make` | `.anthropic` → `AnthropicClient` |
| OpenAI adapter | `Starcat/Features/AI/OpenAIClient.swift` | 不动 |
| 本地 adapter | `Starcat/Features/AI/LocalAI/LocalMLXClient.swift` | 不动 |
| Provider 枚举 | `Starcat/Core/Settings/AppSettings.swift` `AIServiceProvider` | 追加 case 与全部 switch |
| 任务门禁 | `AISettingsView.eligibleVerifiedProfiles` / `AIConfiguration.resolveEmbeddingSelection` | Embedding 已按 `supportsEmbeddingEndpoint` 过滤，接上即可 |
| Agent 装配 | `Starcat/Features/Agents/Core/AgentLoopModelClient.swift` | 继续 `AIClientFactory.make`；不为 Anthropic 另写 Runtime |
| 用量 | `AIUsageEventFactory` 已写 `providerKind: configuration.provider.rawValue` | 无需新表；定价目录可后补 Claude 价目，缺省为 unknown cost |
| 设置 UI | `Starcat/Features/Settings/AISettingsView.swift` | `userSelectableCases` 自动包含新 case；输入行复用 |

`AIChatMessage` 已是内部模型（`user` / `assistant` / `tool` + `toolCallID`）。Anthropic 的 `tool_use` / `tool_result` 只在 adapter 编解码，不扩散到 ViewModel。

## 5. 架构

```text
摘要 / Chat / RAG / 翻译 / AgentLoop
        │
        ▼
 AIClientFactory.make(configuration)
        │
        ├── .localAI     → LocalMLXClient
        ├── .anthropic   → AnthropicClient    ← 本方案
        └── 其他         → OpenAIClient
```

`AnthropicClient` 实现完整 `AIClientProtocol`：

- `chat` / `chatStream`：Messages API
- `listModels` / `testConnection`：优先 `GET /v1/models`，失败则用内置目录 + 一次最小 messages 探测
- `embedding` / `embeddings`：抛 `AIEmbeddingError.incompatibleModel` 的上游门禁不应点到这里；若被误调，抛 `AIClientError.requestRejected(statusCode: 400, detail: "Anthropic does not provide embeddings")`

## 6. Provider 枚举落地

在 `AIServiceProvider` **所有** switch 补 `.anthropic`。遗漏任何一个会编译失败，这是预期。

| 属性 | 值 |
|---|---|
| `rawValue` | `anthropic` |
| `displayName` | `"Anthropic"`（设置 Picker 英文专名，与 DeepSeek / OpenRouter 一致） |
| `defaultProfileName` | `"Anthropic"` |
| `defaultBaseURL` | `https://api.anthropic.com` |
| `defaultChatModel` | `claude-sonnet-4-5` |
| `defaultEmbeddingModel` | `""`（与 OrcaRouter 相同：占位空串，任务门禁拦截） |
| `supportsEmbeddingEndpoint` | `false`（与 `.orcaRouter` 并列，不要进 `default: true`） |
| `allowsEmptyAPIKey` | `false` |
| `iconAssetName` | `"claudecode"` |
| `fallbackSystemImageName` | `"sparkles"` |
| `iconIsMonochromeWhite` | `false`（Claude Spark 是彩色原图） |
| `userSelectableCases` | 自动包含（只要不是 `localAI`） |

`supportsEmbeddingEndpoint` 当前已包含 Anthropic 排除分支：

```swift
switch self {
case .orcaRouter, .anthropic: return false
default: return true
}
```

维护时保留该限制，不能把“支持聊天”推导为“支持 Embedding”。

## 7. URL 归一

用户 / CC Switch 常见三种 Base URL：

| 输入 | 归一后的 messages URL |
|---|---|
| `https://api.anthropic.com` | `https://api.anthropic.com/v1/messages` |
| `https://api.anthropic.com/v1` | `https://api.anthropic.com/v1/messages` |
| `https://api.deepseek.com/anthropic` | `https://api.deepseek.com/anthropic/v1/messages` |
| `https://api.deepseek.com/anthropic/v1` | `https://api.deepseek.com/anthropic/v1/messages` |

规则（实现为 `AnthropicEndpoint.normalize(baseURL:)`，单测覆盖上表）：

1. Trim 空白，去掉末尾 `/`。
2. 非法 URL 抛 `AIClientError.invalidBaseURL`。
3. 若 path 已以 `/v1` 结尾（或 `/v1/`），则 `messagesURL = base + "/messages"`，`modelsURL = base + "/models"`。
4. 否则 `messagesURL = base + "/v1/messages"`，`modelsURL = base + "/v1/models"`。
5. 禁止把 `/anthropic` 改写成 `/v1`。那是另一套协议，属于 OpenAI 兼容入口。

## 8. 请求 / 响应编解码

### 8.1 公共请求头

```
content-type: application/json
anthropic-version: 2023-06-01
x-api-key: <key>
Authorization: Bearer <key>
```

超时用 `AIClientConfiguration.timeoutInterval`（默认 300s），与 OpenAIClient 的诊断 `URLSession` 一致。DEBUG 下可复用 `AIHTTPDebugURLProtocol` 的拦截思路，但只匹配 path 含 `/messages` 的请求，不要改现有 `/chat/completions` 拦截条件导致双边都丢。

### 8.2 `chat` 请求体

```json
{
  "model": "<resolvedModel>",
  "max_tokens": <clamped>,
  "temperature": <0...1>,
  "top_p": <optional>,
  "top_k": <optional, >0 才传>,
  "stream": false,
  "system": "<systemPrompt>",
  "messages": [ ... ],
  "tools": [ ... ],
  "tool_choice": { "type": "auto" }
}
```

约束：

- `max_tokens` **必填**。取 `request.parameters.maxCompletionTokens`，钳制到 `1...32768`。Starcat 默认 128K，直接传给 Anthropic 会被拒。
- `temperature` 钳制 `0...1`。
- `systemPrompt` 为空则省略 `system` 键。
- `disableThinking == true`：不传 `thinking`。
- `includeUsage`：Anthropic 默认返回 `usage`，无需 `stream_options`。
- 图片：`request.images` 转成 user 内容块 `{ "type": "image", "source": { "type": "base64", "media_type": "<contentType>", "data": "<b64>" } }`。只支持 `image/jpeg`、`image/png`、`image/gif`、`image/webp`；其他类型抛 `AIClientError.requestRejected(statusCode: 400, detail:)`。

### 8.3 messages 数组

顺序：历史 `request.history` → 当前 `userPrompt`（及图片）。**不要**把 system 放进 messages。

| `AIChatMessage.role` | Anthropic |
|---|---|
| `.user` | `{ "role": "user", "content": "<text>" }` |
| `.assistant` 无 tool | `{ "role": "assistant", "content": "<text>" }` |
| `.assistant` 有 `toolCalls` | `content` 为 text 块（可空）+ 若干 `tool_use` 块 |
| `.tool` | 见下一节，不能单独作为 `role: tool`（Anthropic 无此 role） |

`tool_use.input` 必须是 JSON 对象。`AIChatToolCall.arguments` 是字符串：

1. `JSONSerialization` 成 object 则用之；
2. 成 array / 标量则包成 `{ "value": ... }`；
3. 解析失败则 `{ "raw": "<原字符串>" }`，保证下一轮仍能回放，不丢审计。

### 8.4 连续 tool 结果必须合并

Anthropic 要求：assistant 的 `tool_use` 之后，下一条必须是 **单条** `role: user`，其 `content` 为全部 `tool_result` 块。

adapter 扫描 history：

- 把相邻的 `.tool` 消息合并成一条 user；
- 每块：`{ "type": "tool_result", "tool_use_id": "<toolCallID>", "content": "<content>" }`；
- 缺 `toolCallID` 抛 `AIClientError.invalidChatHistory("tool message is missing tool_call_id")`，与 OpenAIClient 同文案语义。

`AgentLoopModelClient` 已经按 tool 消息拆条，合并只发生在 Anthropic adapter。

### 8.5 tools 声明

```json
{
  "name": "<AIChatTool.name>",
  "description": "<description>",
  "input_schema": <AgentJSONSchema JSON>
}
```

`toolChoice`：

| Starcat | Anthropic |
|---|---|
| `.none` | 不传 `tools`，或 `"tool_choice": { "type": "none" }` |
| `.auto` | `{ "type": "auto" }` |
| `.required` | `{ "type": "any" }` |
| `.tool(name)` | `{ "type": "tool", "name": "<name>" }` |

`parallelToolCalls`：Anthropic 无对等字段。忽略；模型可能仍一次返回多个 `tool_use`，adapter 原样收进 `[AIChatToolCall]`。

### 8.6 `.jsonObject`

在现有 `tools` 之外追加（若业务已传 tools，仍追加）：

```json
{
  "name": "starcat_json_result",
  "description": "Return the JSON object required by the user request.",
  "input_schema": {
    "type": "object",
    "additionalProperties": true
  }
}
```

`tool_choice` 强制 `{ "type": "tool", "name": "starcat_json_result" }`。

响应处理：

- 若存在该 tool_use：把 `input` 重新 JSON 编码写入 `AIChatResponse.content`，`toolCalls` **不含** 这一条（避免 Agent 把它当真实工具执行）；
- 若模型无视强制 tool、只回了文本：把文本当作 `content`（与现有 JSON 解析兜底一致，翻译 / 摘要已能从正文抠 JSON）。

名称 `starcat_json_result` 固定，禁止与 Agent 工具重名；Agent 路径使用 `.text`，不会走到这个分支。

### 8.7 非流式响应映射

读 `content` 数组：

| block.type | 动作 |
|---|---|
| `text` | 拼到 `content` |
| `thinking` | 拼到 `reasoningContent` |
| `tool_use` | 追加 `AIChatToolCall(id:name:arguments:)`，`arguments` 为 input 的 JSON 字符串 |
| 其他 | 忽略 |

`stop_reason`：

- `max_tokens` → 抛 `AIClientError.responseTruncated`（与 OpenAI `length` 对齐）
- `end_turn` / `stop_sequence` / `tool_use` → 正常完成，`finishReason` 用原字符串
- 空 content 且无 tool_use → `AIClientError.emptyResponse`

`usage`：`input_tokens` / `output_tokens` → `AIChatUsage`；`cachedTokens` / `reasoningTokens` 无则 0；`totalTokens = input + output`。

错误 HTTP 映射复用 `OpenAIClient.mapChatFailure` 的状态码语义，抽一层共享函数或在 `AnthropicClient` 内复制同一套 case（401/403 → authenticationRejected，429 → rateLimited，402 → paymentRequired，400/404/422 → requestRejected，5xx/URLError → networkUnavailable / timedOut）。产品文案走现有 `AIClientError.errorDescription`，不新造用户可见错误类型。

响应 body 里 Anthropic 常见 `{ "error": { "type", "message" } }`，把 `message` 放进 `detail`。禁止把 API Key 或完整 request JSON 打进 `AppLog` 的 public 字段；DEBUG dump 必须先 redact `x-api-key` / `Authorization`。

### 8.8 流式

`stream: true`，按 SSE 解析：`event:` + `data:`。忽略 ping / 空 data。

| event | data 要点 | 产出 |
|---|---|---|
| `content_block_start` type `tool_use` | id / name | 记住 index → 累加器 |
| `content_block_delta` `text_delta` | `delta.text` | `.delta` |
| `content_block_delta` `thinking_delta` | `delta.thinking` | `.reasoningDelta` |
| `content_block_delta` `input_json_delta` | `delta.partial_json` | `.toolCallDelta` |
| `message_delta` | `usage` / `stop_reason` | `.usage`；记下 stop |
| `message_stop` | | 冲刷 reasoning normalizer；`.completed` |

实现注意：

- 取消时 `continuation.onTermination` 必须 `URLSessionTask.cancel()`，并按 OpenAIClient 同样记 `cancelled` 用量。
- URLSession SSE：用 `bytes(for:)` 按行解析，不要等整个 body。
- `receivedChunk == false` 且失败时不要重试改协议；Anthropic 没有 `stream_options` 兼容包袱。

流结束后若 `stop_reason == max_tokens` 同样抛 `responseTruncated`。

## 9. 模型列表与连接测试

### 9.1 `listModels`

1. `GET modelsURL`，带同一套鉴权头。
2. 成功则解析 Anthropic `{ "data": [ { "id": "claude-..." } ] }`，映射为 `AIModelDescriptor(capability: inferred(from: id))`。
3. HTTP 404 / 405 / 未实现：回落到 `AnthropicModelCatalog.bundled`（写死在代码里的官方常用 id，至少含 `claude-opus-4-1`、`claude-sonnet-4-5`、`claude-haiku-4-5`）。中转经常没有 `/models`。
4. 401 / 403：当作鉴权失败上抛，不要静默用目录（否则测试会“成功”但后续 chat 全 401）。
5. 与 `AIProviderProfile.maxStoredModels` 的合并仍由设置页 `mergeDiscoveredModels` 负责。

### 9.2 `testConnection`

设置页 `testAndFetchModels` 调的是 `listModels()` 再合并，不是 `testConnection()`。为协议完整仍实现 `testConnection()` = `listModels()`；若走了 bundled fallback，再发一次最小 messages：

```json
{ "model": "<defaultChatModel>", "max_tokens": 8, "messages": [{ "role": "user", "content": "ping" }] }
```

失败则测试失败。成功则设置页仍以 `listModels` 返回的目录为准。

`AISettingsView.testAndFetchModels` **不用改控制流**。Anthropic 的 Key / Base URL 校验与现有 `canTest` 相同：非空 Key + 非空 Base URL。

## 10. 工厂与用量

```swift
enum AIClientFactory {
    static func make(configuration: AIClientConfiguration) throws -> any AIClientProtocol {
        if configuration.provider == .localAI {
            return LocalMLXClient.makeClient(configuration: configuration)
        }
        if configuration.provider == .anthropic {
            return try AnthropicClient(configuration: configuration)
        }
        return try OpenAIClient(configuration: configuration)
    }
}
```

`AnthropicClient` 在 `chat` / `chatStream` 成功、失败、取消时调用现有 `AIUsageEventFactory` + `AIUsageRecorder`，`operation` 与 OpenAI 的 chat 一致。不要为 Anthropic 新建 usage 表。

`AIUsagePricing.providerAlias` 把 `anthropic` 映射为 `anthropic` / `claude` 别名；目录暂无价目时估价为 nil，与未知 OpenAI 兼容模型相同。

## 11. 文件清单

新增：

| 文件 | 职责 |
|---|---|
| `Starcat/Features/AI/Anthropic/AnthropicClient.swift` | `AIClientProtocol` 实现、SSE、错误映射、用量 |
| `Starcat/Features/AI/Anthropic/AnthropicEndpoint.swift` | Base URL 归一 |
| `Starcat/Features/AI/Anthropic/AnthropicMessagesCodec.swift` | 请求/响应/历史/tool 编解码 |
| `Starcat/Features/AI/Anthropic/AnthropicModelCatalog.swift` | bundled 模型 id |
| `StarcatTests/AnthropicEndpointTests.swift` | URL 归一 |
| `StarcatTests/AnthropicMessagesCodecTests.swift` | 历史合并、jsonObject tool、stop_reason |
| `StarcatTests/AnthropicClientTests.swift` | `URLProtocolStub` 测 chat / stream / listModels / 401 |

修改：

| 文件 | 改动 |
|---|---|
| `Starcat/Features/AI/AIClient.swift` | 工厂分支 |
| `Starcat/Core/Settings/AppSettings.swift` | 枚举 + 全部 switch；`supportsEmbeddingEndpoint` |
| `Starcat/Features/AI/AIConfiguration.swift` | `defaultProfileName` 等若独立 switch |
| `Starcat/Features/AI/Usage/AIUsagePricing.swift` | `providerAlias("anthropic")` |
| `StarcatTests` 中穷举 `AIServiceProvider.allCases` 的测试 | 补新 case |
| `project.yml` | 若 xcodegen 未用目录通配，需能看到新 Swift 文件；本仓通常通配，改完跑 `xcodegen generate` |
| `Starcat/Resources/Localizable.xcstrings` | 仅当出现新用户文案；优先复用 `ai.client.error.*`。若设置页要一行说明「该服务商不支持 Embedding」，新增 `settings.ai.provider.anthropic.embeddingUnsupported`（en + zh-Hans）。Catalog 只允许按行插入，禁止整文件格式化 |

不改：`OpenAIClient.swift`、Agent Runtime、RAG Planner、Keychain schema、数据库 migration、`功能实现总览.md`（等 dong4j 确认后再勾）。

## 12. 实施顺序

1. 补 `AIServiceProvider.anthropic` 与所有 switch，编译通过。
2. 落地 `AnthropicEndpoint` + 单测。
3. 落地 `AnthropicMessagesCodec` + 单测（含 tool 合并、jsonObject）。
4. 落地 `AnthropicClient`（非流式 chat → listModels → stream → embedding 拒绝）。
5. 改 `AIClientFactory`。
6. `URLProtocolStub` 集成测试：200 text、200 tool_use、401、max_tokens、SSE 两帧。
7. 设置页手测：新增 Anthropic、填官方或中转 URL、测试成功、摘要任务可选、Embedding 任务不可选、对话能出字。
8. Agent 工作台选该 Provider 的 chat 模型，确认能发起一次无工具回合；再确认带工具回合的 `tool_use` 能被 Runtime 执行（adapter 映射正确即可，不改 Runtime）。

跑测：关闭 Xcode IDE 后

```bash
make test TEST_ARGS="-only-testing:StarcatTests/AnthropicEndpointTests -only-testing:StarcatTests/AnthropicMessagesCodecTests -only-testing:StarcatTests/AnthropicClientTests"
```

## 13. 测试契约

### 13.1 `AnthropicEndpointTests`

- 第四节表格 4 种输入 → messages / models URL。
- 空串、无 scheme、仅 path → `invalidBaseURL`。
- 末尾多个 `/` 只剥一层循环到稳定。

### 13.2 `AnthropicMessagesCodecTests`

- system + 单轮 user。
- assistant toolCalls + 两条相邻 tool → 一条 user 含两个 `tool_result`。
- tool 缺 id → `invalidChatHistory`。
- `.jsonObject` 注入强制 tool 且 tool_choice 为该 name。
- `max_tokens` 128*1024 被钳成 32768。
- `stop_reason=max_tokens` 映射 `responseTruncated`。
- `starcat_json_result` 的 tool_use 进入 `content` 而不进入 `toolCalls`。

### 13.3 `AnthropicClientTests`

用现有 `URLProtocolStub`（参考 `OpenAIClientToolCallingTests`）：

- 非流式 text 200 → content / usage。
- 流式两帧 text_delta + message_stop → delta 事件 + completed。
- 401 JSON error → `authenticationRejected`。
- `/models` 404 → bundled 目录非空，且随后 ping messages 被调用（可用 stub 计数）。
- `/models` 401 → 测试失败，不回落目录。
- `embedding` 直接失败。
- Task 取消 → `CancellationError`，不映射成 `requestFailed`。

Key 断言：日志与错误 `detail` 不含完整 API Key。

## 14. 验收

- 设置页能新增 Anthropic，默认 URL 为 `https://api.anthropic.com`。
- 填真实 Key 后「测试并获取模型」成功，profile 进入正式列表。
- Chat / 摘要 / 翻译任务可选该 profile；Embedding 任务列表不含它。
- 对话流式出字；取消立即停。
- Agent 内置 Runtime 可选该 profile 的 Chat 模型；工具调用至少一轮往返成功（用可 mock 的中转或 stub）。
- 把 Base URL 改成 `https://api.deepseek.com/anthropic` 时，实际请求打到 `.../anthropic/v1/messages`，而不是 DeepSeek 的 `/chat/completions`。
- App Store / Direct 行为一致（本方案无沙盒差异）。

## 15. 回滚

删除工厂分支与新文件，枚举 case 若已有用户选中该类型：解码 `AIServiceProvider` 会失败。因此 **一旦随正式版发出，禁止删除 case**；若要撤回能力，保留枚举，工厂对 `.anthropic` 抛明确错误并在设置页提示「当前版本暂不可用」。未发版前可直接删 case。

## 16. 与文档 69 的衔接

文档 69 的导入器在 `AIServiceProvider` 含 `.anthropic` 且工厂能构造 `AnthropicClient` 时，把 CC Switch 的 Claude / `*/anthropic` URL **原样**导入为 `.anthropic`，不再改写成 OpenAI Base URL。两方案可分 PR，但建议先合 68 再合 69，避免导入后再改类型。
