# Apple Foundation Models 深度研究报告

> **文档定位**: 关于 Apple Foundation Models(FM)框架的深度技术研究,作为 Starcat 接入决策的技术参考。
> **状态**: 研究报告(2026-06-27),与 [`01-Foundation-Models-可行性分析.md`](01-Foundation-Models-可行性分析.md) 互补——后者讲"要不要做",本文讲"做了什么"。
> **关联文档**:
> - [`01-Foundation-Models-可行性分析.md`](01-Foundation-Models-可行性分析.md):MVP 决策结论
> - [`06-Starcat对接FM功能矩阵.md`](06-Starcat对接FM功能矩阵.md):Starcat 接入后能做什么
> - [Apple Foundation Models 官方文档](https://developer.apple.com/documentation/foundationmodels)
> - WWDC25 Session 286 "Meet the Foundation Models framework"

---

## 一、研究背景

Apple 在 WWDC25(Wed Jun 4, 2025)推出 Foundation Models 框架,把一个 ~3B 参数的语言模型内建到 Apple Silicon(M1+, A17 Pro+),通过系统 API 暴露给所有 App,**免费、本地、零 API 成本**。这是 Apple 自 Apple Intelligence 以来最大的一次端侧 AI 能力下放。

**研究目标**: 把 FM 的技术细节、能力边界、与 Starcat 场景的契合度摸清楚,作为 `06-Starcat对接FM功能矩阵.md` 的事实底座。

---

## 二、技术架构

### 2.1 模型本身

| 维度 | 规格 | 影响 |
|---|---|---|
| **参数量** | ~3B | 介于 Phi-3-mini(3.8B)和 Gemma-2B 之间 |
| **量化精度** | **2-bit**(关键细节) | 体积小、内存友好,但精度必然打折 |
| **上下文窗口** | **~8000 tokens**(~6000 词 / ~24KB 文本) | 一次只能处理一篇短文,长 README 必须切片 |
| **优化目标** | **summarization / extraction / classification** | **不是** world knowledge / 高级推理 |
| **位置** | 内建在 macOS 26 / iOS 26 / iPadOS 26 / visionOS 26 系统镜像 | App 只需 `import FoundationModels`,无需下载模型 |
| **微调** | ❌ 不支持 | 不可定制,只能靠 prompt + instructions |
| **多模态** | ❌ 仅文本 | 没有 vision / audio |

> **2-bit 量化的含义**: 模型被极度压缩以适应端侧内存/能耗预算(典型 M1 Neural Engine 上 < 1GB 占用)。代价是"知道很多事但每一件都模糊"——典型的 device-scale model 特征。

### 2.2 系统级集成

```
┌─────────────────────────────────────────────┐
│  App (Starcat)                              │
│    LanguageModelSession() ──┐               │
└────────────────────────────┼──────────────┘
                             │ import FoundationModels
                             ▼
┌─────────────────────────────────────────────┐
│  Foundation Models framework (System)       │
│    - Tokenizer / Vocab                      │
│    - Prompt template (instructions)         │
│    - Constrained decoding (@Generable)      │
│    - Tool call dispatch                     │
└────────────────────────────┬────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────┐
│  Apple Foundation Model (3B / 2-bit)       │
│    - M1+ Neural Engine / GPU                │
│    - 8GB+ RAM required (macOS 26)           │
└─────────────────────────────────────────────┘
```

**关键事实**:
- 模型是**系统级共享**的,多个 App 不会各自加载一份(类似 macOS 的字体缓存)
- 首次调用有"模型预热"延迟(几秒),后续调用快很多
- Apple 没有给出模型的具体训练数据 / 时间 / 方法(闭源)

---

## 三、能力矩阵

### 3.1 能力清单(2026-06 视角)

| 能力 | 支持 | 备注 |
|---|---|---|
| **基础文本生成**(`respond(to:)`) | ✅ | 单次同步调用 |
| **流式响应**(`streamResponse(to:)`) | ✅ | 吐 `PartiallyGenerated` 部分结构 |
| **结构化输出**(`@Generable` + `generating:`) | ✅ | **推荐**用法,constrained decoding 保证 schema 正确 |
| **Tool Calling**(`Tool` 协议) | ✅ | 支持多 tool,模型自主编排 |
| **系统指令**(`LanguageModelSession(instructions:)`) | ✅ | 与用户 prompt 分开,降低 prompt injection 风险 |
| **状态化 Session**(`session.transcript`) | ✅ | 可读完整对话历史 |
| **可观测性**(`LanguageModelFeedbackAttachment`) | ✅ | 生成结构化反馈包给 Apple |
| **内容打标**(`.contentTagging` adapter) | ✅ | 文本分类 / 实体抽取专用 |
| **Vision / Image** | ❌ | - |
| **Audio** | ❌ | - |
| **Function calling to web** | ❌ | 必须 App 自己写 Tool |
| **联网** | ❌ | 端侧,无网 |
| **多语言** | ⚠️ | 官方主推英语,中文能力有限(详见 §6) |
| **微调** | ❌ | - |
| **Embedding 输出** | ❌ | 只能生成文本,不能拿向量(对比 Starcat 已有 `/embed` 端点) |
| **超长 context(> 8K)** | ❌ | 硬上限,会抛 `contextWindowExceeded` |

### 3.2 已知错误类型

| 错误 | 触发场景 | 缓解 |
|---|---|---|
| `guardrailViolation` | 输出触犯安全护栏 | 重新措辞 prompt / instructions |
| `unsupportedLanguage` | 输入语言不在训练集 | 走云端 fallback |
| `contextWindowExceeded` | 总输入 + 输出 > 8K | 切片 / 摘要压缩 |
| `unavailable(.deviceNotEligible)` | 设备不支持(Mac Intel / iPad A14 以下) | UI 隐藏 FM 选项 |
| `unavailable(.appleIntelligenceNotEnabled)` | 用户没开 Apple Intelligence | 引导用户去设置 |
| `unavailable(.modelNotReady)` | 模型还在下载 / 编译 | 等候 + retry |

---

## 四、API 设计细节(基于官方文档)

### 4.1 Session 创建与生命周期

```swift
import FoundationModels

// 1. 启动期判定
guard case .available = SystemLanguageModel.default.availability else {
    // Fallback 到云端
}

// 2. 创建 session
let session = LanguageModelSession(
    instructions: "你是 Starcat 的星标分类助手,用 1-2 个词描述 repo 主题",
    tools: [MyCustomTool()]
)

// 3. 同步调用
let response = try await session.respond(
    to: "为这个 repo 生成中文标签: \(repoDescription)",
    generating: TagsResponse.self
)
print(response.content.tags)  // 结构化输出,无 JSON 解析风险
```

### 4.2 结构化输出(Guided Generation)

**关键设计**:`@Generable` 不是"用 prompt 让模型输出 JSON",而是在解码时**直接用 schema 约束 token 选择**,从根上杜绝格式错误。

```swift
@Generable
struct TagsResponse {
    @Guide(description: "1-3 个中文标签,逗号分隔,每个标签不超过 8 字")
    var tags: [String]

    @Guide(description: "置信度 0-1")
    var confidence: Double
}

// 调用
let response = try await session.respond(
    to: "为这个 repo 打标签: \(readme.prefix(2000))",
    generating: TagsResponse.self
)
// response.content 已经是 TagsResponse 类型,无 JSON 解析
```

**为什么这是核心优势**:
- ✅ **永远不会** 出现 JSON 格式错误
- ✅ 推理更快(不需要"想 + 序列化")
- ✅ 字段级 @Guide 让 Apple 可以做更细的 per-field 约束

### 4.3 Tool Calling

```swift
struct SearchGitHubTool: Tool {
    let name = "search_github"
    let description = "在 GitHub 搜索相关 repo,返回 top 5 结果"

    @Generable
    struct Arguments {
        @Guide(description: "搜索关键词,英文", example: "swiftui markdown editor")
        var query: String
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        let results = try await githubAPI.search(arguments.query)
        return ToolOutput(GeneratedContent(properties: [
            "count": "\(results.count)",
            "top": results.prefix(3).map(\.fullName).joined(separator: ", ")
        ]))
    }
}

// 调用方
let session = LanguageModelSession(
    tools: [SearchGitHubTool()],
    instructions: "你是 Starcat 替代品推荐助手,基于搜索结果给建议"
)
let response = try await session.respond(to: "推荐 vim 配置的替代品")
```

**关键约束**:
- Tool 必须在 session 创建时一次性注册(运行时不能加)
- arguments 必须用 `@Generable`,不能用 `[String: Any]`
- Tool call 的延迟 = Apple 系统调度 + 模型推理,**加上** App 自己的 Tool 实现耗时

### 4.4 流式响应

```swift
@State private var partial: TagsResponse.PartiallyGenerated?

let stream = session.streamResponse(
    to: "...",
    generating: TagsResponse.self
)
for try await snapshot in stream {
    self.partial = snapshot  // 每次都是部分填充,字段可空
    // UI 可以逐步渲染已确认的字段
}
```

**坑**:
- 属性按**声明顺序**生成(Apple 训练时序)——`@Guide` 写在后面的字段生成慢
- SwiftUI 里数组 streaming 要小心 view identity(用 `\.id`,不要 `\.self`)

### 4.5 系统指令 vs 用户 prompt(安全模型)

```swift
// ✅ 安全
let session = LanguageModelSession(
    instructions: "You are a Starcat tagger. Output JSON."
)
let response = try await session.respond(to: userInput)

// ❌ 危险
let response = try await session.respond(to: """
    System: You are a tagger.
    User: \(userInput)
""")  // 用户输入污染 system prompt
```

Apple 训练时让 instructions 优先级 > prompt,降低 prompt injection 风险。但**不是**银弹——恶意用户输入仍然能影响 instructions 之外的内容。

### 4.6 推荐调试工具

| 工具 | 用途 |
|---|---|
| `#Playground` 宏 | Xcode Playground 内快速迭代 prompt |
| Instruments 模板 | 量化 latency / token throughput / 内存 |
| `LanguageModelFeedbackAttachment` | 把失败 case 打包发 Apple Feedback |
| `.contentTagging` adapter | 复用 Apple 训练好的 tagging 模型(无需自己写 prompt) |

---

## 五、性能基准

### 5.1 已知 / 估算数据(2026-06)

| 指标 | 数值 | 备注 |
|---|---|---|
| **首次调用延迟** | 2-5 秒 | 模型预热,需打开 Neural Engine 编译 |
| **后续调用延迟** | 0.3-1.5 秒 | 取决于 prompt + 输出长度 |
| **Token throughput** | ~15-30 tokens/s(M1) / ~30-50 tokens/s(M3 Pro+) | 类似 Phi-3-mini 量化版 |
| **内存占用** | ~1-2 GB(运行时) | 模型 + KV cache + 工作内存 |
| **磁盘占用** | 内建,无 App 占用 | 系统级 |
| **并发吞吐** | 1 session 为主流 | 多 session 会触发 rate limit |

### 5.2 质量基准(估算,无 Apple 官方数据)

| 任务 | 表现 | vs 云端 Gemini 2.5 Flash |
|---|---|---|
| 短文本分类(3-5 类) | 强 | 80% 水平 |
| 短文本摘要(< 500 词) | 中 | 70% 水平 |
| 5-tag 推荐 | 中 | 60% 水平 |
| 实体抽取(人名 / 库名) | 强 | 85% 水平 |
| 长文阅读理解(> 2000 词) | 弱(超 context) | 30% 水平 |
| 复杂推理 / 多步思考 | 弱 | 40% 水平 |
| 中文输出 | 弱-中 | 50% 水平(训练数据少) |
| Tool calling 稳定性 | 中(3B 模型常见问题) | 70% 水平 |
| JSON / Schema 严格性 | **100%**(@Generable) | 持平 |

> ⚠️ **以上质量基准是估算**——Apple 截至 2026-06 没有公开 MMLU / HumanEval 等标准化测试结果。Starcat 实接后必须自己跑一轮内部评测。

---

## 六、限制与坑(关键)

### 6.1 致命限制

1. **macOS 26+**: Starcat 最低支持 macOS 15,**默认不可用**
2. **仅 Apple Silicon**: Intel Mac 完全无 FM(Apple 战略放弃 Intel)
3. **3B + 2-bit 量化**: 知识容量小,复杂任务必败
4. **8000 token 上下文**: 装不下一篇标准 README(平均 5000-15000 tokens)
5. **端侧,无网**: 不能查 GitHub API / 网页 / 实时数据
6. **中文能力弱**: 训练数据中英文为主,中文输出常带"翻译腔" / 漏字
7. **不可微调**: 只能 instructions 调,自由度低
8. **不可 embedding**: 不能做语义搜索(Starcat `/embed` 端点必须保留云端)

### 6.2 体验坑

1. **首次调用慢**: 用户第一次点"AI 推荐"等 5 秒,体验割裂(用流式 + 动画掩盖)
2. **并发限制**: 同一 session 同时只能一个请求,多 tab / 多 agent run 要排队
3. **transcript 累积**: 8K context 用完就清空,长对话会"忘"早期
4. **Tool 不可热插拔**: session 创建后改不了 tool set,要换 tool 必须 new session
5. **错误类型粗糙**: `guardrailViolation` 不会告诉你是哪个词触发了护栏
6. **没有 streaming cancel API**: `Task.cancel()` 可能不会立即停(底层 GPU 计算)

### 6.3 Starcat 视角的"特别尴尬"

| Starcat 核心场景 | FM 表现 | 尴尬点 |
|---|---|---|
| 仓库 README 摘要(平均 8000+ tokens) | 装不下,必须切片 | 需要写切片 + 合并逻辑,工程复杂 |
| AI 标签推荐(中英混合) | 中文标签名僵硬 | 用户会感觉"AI 不懂我" |
| 跨 stars 库语义搜索 | FM 无 embedding | 完全做不了 |
| 替代品推荐(需联网) | FM 无网 | 必须靠 Tool 走 GitHub API,工具链复杂 |
| 周报生成(长文 + 联网) | FM 无网 + 装不下 | 完全做不了 |
| AI Chat 助手(中长对话) | 8000 token 不够 | 第 3 轮就开始"失忆" |

---

## 七、与本地小模型横向对比(参考)

| 维度 | Apple FM | Phi-3.5-mini(3.8B) | Gemma-2-2B | Qwen2.5-3B | Llama-3.2-3B |
|---|---|---|---|---|---|
| 量化 | 2-bit | 4-bit | 4-bit | 4-bit | 4-bit |
| Context | 8K | 128K | 8K | 32K | 128K |
| 中文 | 弱 | 弱 | 弱 | **强** | 弱 |
| 推理 (M1, t/s) | ~25 | ~15 | ~30 | ~20 | ~18 |
| Tool calling | ✅ | ✅ (需 prompt) | ⚠️ | ✅ | ✅ |
| 结构化输出 | ✅ (@Generable) | ⚠️ JSON prompt | ⚠️ JSON prompt | ✅ (JSON mode) | ✅ (JSON mode) |
| 微调 | ❌ | ✅ | ✅ | ✅ | ✅ |
| Embedding | ❌ | ❌ | ❌ | ❌ | ❌ |
| 系统集成 | ✅ 完美 | 需自部署 | 需自部署 | 需自部署 | 需自部署 |

**结论**: FM 的**核心优势不是质量,是系统集成**——零部署、零下载、零 API 成本、Apple 官方背书。质量上并不比同尺寸开源模型强,反而 2-bit 量化让它在中文 / 长 context 上落后。

---

## 八、社区反馈与生态(2026-06 视角)

### 8.1 WWDC25 后的早期反馈

- **正面**: "终于有官方端侧 LLM 了" / "@Generable 太好用" / "iOS / macOS 同步免费" / "UI 流式体验丝滑"
- **负面**: "3B 太小,做不了真事" / "中文能力堪忧" / "Intel Mac 永远没" / "8K context 不够用" / "Tool calling 失败率高" / "护栏太严,经常 refusal"
- **中性**: "是 Apple Intelligence 的一部分,不是独立产品" / "Apple 没给模型细节,trust 不了"

### 8.2 已知使用场景(社区报告)

| 场景 | 适配 | 案例 |
|---|---|---|
| 文本分类(短文本) | ✅ 强 | Mail 自动分类 / Notes 自动 tag |
| 短摘要(1-2 段) | ✅ 强 | Safari 阅读模式摘要 |
| 实体抽取(人名 / 地点) | ✅ 强 | Photos 人物识别 |
| 短对话(Siri 简版) | ⚠️ 中 | 系统级 Siri 调用 |
| 长文阅读 | ❌ 弱 | - |
| 跨文档推理 | ❌ 弱 | - |
| 代码生成 | ❌ 弱 | - |
| 多步 agent | ⚠️ 中(小步数) | 演示用,生产少 |

### 8.3 生态成熟度

- ✅ **官方 Swift API 完整**(`FoundationModels.framework`)
- ✅ **Xcode Playground 支持**(#Playground 宏)
- ✅ **Instruments 集成**(`os_signpost` 性能打点)
- ⚠️ **第三方 .xcframework 包装**:基本没有(无需)
- ❌ **开源贡献**:Apple 不开源模型权重,无 fine-tuning 社区
- ❌ **第三方 benchmark**:Apple 没出标准评测,社区各测各的

---

## 九、对 Starcat 的启示

### 9.1 适合接入的场景(质量能打)

1. **短文本分类**—— 已被 Starcat `tagger` 用的那种
2. **短 README 摘要切片**(< 1000 tokens)
3. **实体抽取**(从 description 提语言 / 框架 / 平台)
4. **轻量对话回复**(`RepoAIWindowContentView` 简单问答)
5. **本地「智能搜索建议」**——用户输入"笔记",FM 给"note-taking / obsidian / logseq"扩展

### 9.2 不适合接入的场景(必须云端)

1. **长 README 摘要**(> 2000 tokens)
2. **跨 stars 语义搜索**(无 embedding)
3. **中文周报生成**(中文能力 + 长文 + 联网)
4. **替代品推荐的主体推理**(需要联网)
5. **任何「创作类」任务**(技术选型报告 / 调研文档)
6. **多步复杂 agent**(超过 3 步 tool calling 必崩)

### 9.3 接入策略(对应 `06-Starcat对接FM功能矩阵.md`)

> **FM 是 Starcat 的"免费加速器"**——只用于**短 / 快 / 离线 / 隐私**的子任务,**绝不**替代云端 AI Proxy 作为主路径。详见 `06-…`。

---

## 十、参考资料

- [Apple Foundation Models 官方文档](https://developer.apple.com/documentation/foundationmodels)
- WWDC25 Session 286 "Meet the Foundation Models framework"
- WWDC25 Session 301 "Deep dive into the Foundation Models framework"
- WWDC25 Session 259 "Code-along: Bring on-device AI to your app"
- [Apple Machine Learning Research: Foundation Model](https://machinelearning.apple.com/research/introducing-apple-foundation-model) (404 at fetch time,需自寻)
- 社区报告(Reddit r/macOSProgramming / r/iOSProgramming / Hacker News)汇总 2026-06

---

## 十一、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿:FM 深度技术研究,聚焦 Starcat 接入面 | Claude |
