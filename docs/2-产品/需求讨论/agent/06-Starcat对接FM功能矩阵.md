# Starcat 对接 Apple Foundation Models 功能矩阵

> **文档定位**: Starcat 集成 Apple Foundation Models(FM)后能实现哪些功能,按 ROI 排序、分级(Free / Pro / 不做)、带具体落地路径。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板立项。
> **关联文档**:
> - [`05-Apple-Foundation-Models-深度研究报告.md`](05-Apple-Foundation-Models-深度研究报告.md):FM 技术细节
> - [`01-Foundation-Models-可行性分析.md`](01-Foundation-Models-可行性分析.md):MVP 决策
> - [`02-替代品推荐-Agent方案.md`](02-替代品推荐-Agent方案.md):云端 agent 范本
> - [`../CLAUDE.md`](../CLAUDE.md):macOS 15+ / AI 保守策略铁律
> - [`../AI代理API设计.md`](../AI代理API设计.md):现有 AI Proxy 协议

---

## 一、对接架构总览

### 1.1 三层架构

```
┌────────────────────────────────────────────────────────┐
│  Starcat App (macOS 15+)                               │
│                                                        │
│  ┌──────────────────────────────────────────────┐    │
│  │  AI Capability Layer (新增)                  │    │
│  │    - CapabilityResolver                      │    │
│  │      根据 (macOS 版本, 设备, 用户偏好)        │    │
│  │      决定: FM 优先 / 云端优先 / 仅云端        │    │
│  │    - FMClient  (FM 后端)                      │    │
│  │    - ProxyClient (云端后端, 已有 AIClient)    │    │
│  └──────────────────────────────────────────────┘    │
│           │              │              │              │
│           ▼              ▼              ▼              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ 短文本能力  │  │ 中等能力    │  │ 重能力      │  │
│  │ (< 2K tok)  │  │ (2K-8K)     │  │ (> 8K)      │  │
│  │ 走 FM       │  │ FM 切片/云  │  │ 仅云端      │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
└────────────────────────────────────────────────────────┘
```

### 1.2 核心原则

> **FM = 免费加速器,不是替代品**。FM 只承担"短 / 快 / 离线 / 隐私"的子任务,主体 AI 路径仍是 Starcat 已有云端 AI Proxy(`AIClient` / `OpenAIClient`)。

### 1.3 与现有 AI Proxy 的关系

- **现有 AI Proxy**(`docs/2-产品/需求讨论/正式方案/AI代理API设计.md`): 统一网关,接 Gemini / OpenAI / DeepSeek,BYOK + 配额 + 鉴权 → **保留不动**
- **新增 FMClient**: 走本地 FM 框架,**不**走 AI Proxy,**不**消耗配额
- **CapabilityResolver**: 在调用前根据任务画像(长度 / 联网 / 中文比例 / 工具需求)选择后端

---

## 二、运行时判定策略

### 2.1 设备能力三态

```swift
enum AICapability {
    case fmAvailable       // macOS 26+ + Apple Silicon + Apple Intelligence 开启
    case cloudOnly         // 不满足 FM 条件,只能云端
    case fmDegraded        // FM 可用但用户主动关 / Apple Intelligence 关闭
}

func resolveCapability() -> AICapability {
    if #available(macOS 26, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return AppSettings.shared.fallbackToCloudOnly ? .cloudOnly : .fmAvailable
        case .unavailable:
            return .cloudOnly
        }
    } else {
        return .cloudOnly
    }
}
```

### 2.2 任务画像 → 后端选择

| 任务画像 | 推荐后端 | 理由 |
|---|---|---|
| 输入 < 500 tokens,无联网,无中文密集,无 tool | **FM** | 延迟低 + 免费 + 隐私 |
| 输入 500-2000 tokens,无联网 | **FM**(切片) | FM 能装下,但要做切片 |
| 输入 2000-8000 tokens | **云端优先** | FM 切片 + 合并成本超过云端 |
| 输入 > 8000 tokens | **仅云端** | FM 装不下 |
| 任何联网需求(实时数据) | **仅云端** | FM 无网 |
| 任何中文密集输出(> 200 字) | **仅云端** | FM 中文弱 |
| 任何多步 tool calling(> 3 步) | **仅云端** | FM tool calling 不稳 |
| 任何 embedding / 语义搜索 | **仅云端** | FM 无 embedding |
| 用户主动选"强制云端"(如调试 / 质量对比) | **仅云端** | 尊重用户选择 |

### 2.3 静默降级 + 用户可见

- FM 调用失败 / 质量明显差 → **静默**降级到云端(不让用户看到错误)
- 但 UI 必须**明确显示**"现在用的是本地模型"或"云端模型",透明度优先
- 用户的反馈(质量差 / 慢)写入 `ai_capability_feedback` 表,反向训练 CapabilityResolver

---

## 三、可以做 vs 不建议做 的功能矩阵

### 3.1 🟢 强推(做)

| # | 功能 | 用户故事 | FM 路径 | 价值 | 用户档 | 工作量 |
|---|---|---|---|---|---|---|
| 1 | **「智能搜索关键词扩展」** | 用户在搜索框输入"笔记",FM 实时给"note-taking / obsidian / logseq / notion"建议词 | FM 一次性,1 个 prompt | 高(降低搜索门槛) | **Free** | 小 |
| 2 | **「Tag 自动补全」** | 用户输入 tag "AI",FM 实时补全候选 "AI Agent / AI 编程 / AI 摘要" | FM 一次性,@Generable 列表 | 中(加速打 tag) | **Free** | 小 |
| 3 | **「Stars 库快速分类」** | 用户首次导入 200 stars,FM 在本地快速分 5-8 大类,云端再精标 | FM 做粗分类(短 description),云端做精标 | **高**(降低首次激活) | **Free** | 中 |
| 4 | **「单 repo 离线摘要」** | 没网 / 飞机上,用户想看某个 repo 的简介 | FM 读本地缓存 README 切片,生成 1 段简介 | 中(场景限定) | **Free** | 小 |
| 5 | **「描述语言识别」** | 新 star 进来,FM 识别主要语言 / 框架 / 平台,自动写元信息 | FM 一次性,@Generable 实体抽取 | 中(辅助搜索 / 过滤) | **Free** | 小 |
| 6 | **「Settings 智能提示」** | 用户看不懂某设置项,FM 读当前设置 + 文档,给 1 段白话解释 | FM 一次性,1 段话 | 中(降支持成本) | **Free** | 小 |
| 7 | **「命令面板自然语言」** | ⌘K 面板输入"清空 30 天前已读 stars",FM 解析为具体操作 | FM Tool Call → Starcat 已有 commands | 中(降低学习成本) | **Free**(基础)/ **Pro**(复杂多步) | 中 |

### 3.2 🟡 可选(看用户反馈)

| # | 功能 | 用户故事 | FM 路径 | 价值 | 用户档 | 工作量 |
|---|---|---|---|---|---|---|
| 8 | **「私有 Note 智能补全」** | 用户写 note 写到一半,FM 补全下一句(只本地,绝不上传) | FM 流式生成 | 中(隐私 + 离线) | **Pro** | 中 |
| 9 | **「批量 AI 标签推荐(粗筛)」** | 200 untagged stars,FM 先在本地粗排 top 50,云端再精排 | FM 批量 + 云端精选 | 中(配额节省) | **Free**(粗筛)/ **Pro**(精排) | 中 |
| 10 | **「对话 Chat 智能回复(轻量)」** | 用户在 RepoAIWindowContentView 问"这个 repo 主要解决啥?",FM 答短回复(2-3 句) | FM 单次生成 | 中(零配额感) | **Free** | 小 |
| 11 | **「健康度单 repo 摘要」** | `RepoHealthSheet` 显示的指标多,FM 给 1 段话总结"这 repo 还在维护吗" | FM 读 health 数据 + 短描述 | 中 | **Free** | 小 |
| 12 | **「Command 解释」** | 用户在 About 看到 "StarsSyncCommand",FM 解释白话 | FM 一次性 | 低 | **Free** | 极小 |

### 3.3 🔴 不建议做(FM 做不了或 ROI 极低)

| # | 功能 | 不做的原因 |
|---|---|---|
| 13 | **替代品推荐 agent** | 需要联网 + 多 tool + 复杂推理,FM 全弱(见 `02-…`) |
| 14 | **技术选型 agent** | 深度推理 + 长文 + 联网,FM 不行 |
| 15 | **Starred 周报生成** | 中文长文 + 联网 + 主题聚类,FM 全弱 |
| 16 | **跨 stars 语义搜索** | FM 无 embedding,完全做不了 |
| 17 | **单 repo README 完整摘要** | 8000 token 装不下,切片后质量更差 |
| 18 | **AI 自动打 tag(主路径)** | 质量不稳,只能做"粗筛"(见 #9),不能替主路径 |
| 19 | **Release 通知 / 趋势分析** | 需要联网 + 时间序列推理,FM 不行 |
| 20 | **任何多步(> 3 步) agent** | 3B 模型 tool calling 失败率随步数指数上升 |

### 3.4 一图总览

```
                    输入大小
              < 2K    2-8K    > 8K
             ┌─────┬───────┬─────┐
  无联网     │ FM  │ 切片  │ 云  │
  (本地)     │ 🥇  │  🟡   │ ❌  │
             ├─────┼───────┼─────┤
  有联网     │ 云  │  云   │ 云  │
  (实时)     │ ❌  │  ❌   │ ❌  │
             ├─────┼───────┼─────┤
  中文密集   │ 云  │  云   │ 云  │
  输出       │ ❌  │  ❌   │ ❌  │
             ├─────┼───────┼─────┤
  Embedding  │ 云  │  云   │ 云  │
             │ ❌  │  ❌   │ ❌  │
             └─────┴───────┴─────┘
```

---

## 四、用户档(Free vs Pro)分配

| 用户档 | 可用 FM 功能 | 配额策略 |
|---|---|---|
| **Free** | #1 搜索扩展 / #2 Tag 补全 / #3 粗筛分类(只前 50)/ #4 离线摘要 / #5 语言识别 / #6 设置解释 / #10 轻量 Chat / #11 健康度摘要 / #12 命令解释 | **零配额消耗**(FM 路径) |
| **Pro** | 上述全部 + #7 命令面板(多步)/ #8 私有 Note 补全 / #9 精排(云端) | FM 部分仍零配额,云端部分按现有 `/quota` 扣 |

> **关键原则**: FM **永远不消耗配额**,这是给 Free 用户的"福利",同时也是 Pro 用户的"加速器"——Pro 用户可以在云端 quota 用完后,继续用 FM 完成基础任务。

---

## 五、UX 设计

### 5.1 透明度

**强制规范**(每处用 FM 都要标):

```swift
// 在 chat 末尾 / 卡片底部署名
HStack {
    Image(systemName: "apple.intelligence")  // 或 "icloud"
    Text("由 本地模型 生成")  // 或 "由 Gemini 2.5 Flash 生成"
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```

**图标语义**:
- 🍎 `apple.intelligence` = Apple FM(本地)
- ☁️ `icloud` = 云端 AI Proxy
- 用户应能一眼看出"刚才那个回复是本机算的,还是发到云端了"

### 5.2 设置页新增 section

```swift
Section("本地 AI 模型") {
    Toggle("启用 Apple Foundation Models", isOn: $settings.fmEnabled)
        .help("macOS 26+ 的端侧 LLM,免费、离线、隐私。")
    Picker("默认后端", selection: $settings.preferredBackend) {
        Text("自动选择").tag(BackendPreference.auto)
        Text("优先本地").tag(BackendPreference.fmFirst)
        Text("仅云端").tag(BackendPreference.cloudOnly)
    }
    HStack {
        Text("当前状态")
        Spacer()
        Text(capabilityStatusText)  // "可用" / "macOS 版本过低" / "未开启 Apple Intelligence"
            .foregroundStyle(capabilityIsOK ? .green : .secondary)
    }
}
```

### 5.3 失败体验

- FM 调失败 → 静默降级云端,UI 显示 "已切换到云端" 一次性 toast
- FM 质量差(用户点 👎)→ 记录反馈,下次**自动**走云端
- 用户可在任何位置点 "切换到云端" 强制走云端(debug 模式常驻)

---

## 六、隐私 / 法务 / 边界

### 6.1 隐私承诺

> **FM 路径: 100% 本地,零数据外发**。**云端路径: 走 Starcat 已有 AI Proxy,按现有隐私策略**。这两条路径必须**严格隔离**,绝不能因为"FM 失败 fallback 云端"就把用户本地数据意外上传。

- FM 调用不写 `AIDebugLogger` 的网络部分(只记 metadata,不记 prompt 内容)
- FM 调用结果**不**进 Starcat 的"AI 推荐历史"(那是云端的)
- 用户 notes 永远不进入 FM prompt(除非用户主动点"用 AI 改写")

### 6.2 法务边界

- Apple FM 使用条款禁止:把 FM 输出作为**训练数据**回流给其他模型 ✅(Starcat 不做)
- Apple FM 不得用于:医疗诊断 / 法律建议 / 金融决策等高风险领域 ✅(Starcat 不做)
- 必须**显著标明**哪些回复由 AI 生成 ✅(UX §5.1 已设计)

### 6.3 数据隔离

| 数据 | FM 路径可见 | 云端路径可见 |
|---|---|---|
| 用户 stars 库 | ✅ | ✅ |
| 用户 notes | ❌ 除非用户主动 | ✅ |
| GitHub token | ❌ | ✅ |
| 用户 API key | ❌ | ✅(Proxy) |
| 内部 metadata | ✅ | ✅ |

---

## 七、Roadmap

### 7.1 MVP(2026 Q3,与 `02-替代品推荐-agent` 并行)

- [ ] `AICapabilityResolver` 实现
- [ ] `FMClient` 实现(封装 `LanguageModelSession`)
- [ ] 功能 #1 智能搜索扩展(ship it,验证 FM 体验)
- [ ] 功能 #2 Tag 自动补全(ship it)
- [ ] 功能 #5 描述语言识别(ship it)
- [ ] 设置页 FM toggle + 状态显示
- [ ] `AboutView.swift` 开源致谢追加(虽然 FM 是系统框架,但 `#Playground` 宏是 Xcode 内置,无需致谢)
- [ ] 单测 + A/B 评测脚本(对比 FM vs 云端质量)
- [ ] `docs/功能实现总览.md` 进度登记

### 7.2 v1.1(2026 Q4,看用户反馈)

- [ ] 功能 #3 粗筛分类(数据驱动决定是否上)
- [ ] 功能 #4 离线摘要
- [ ] 功能 #7 命令面板自然语言
- [ ] 用户反馈表 `ai_capability_feedback` + 自动降级逻辑

### 7.3 v1.2(2027 Q1,如果 macOS 26 装机率 > 50%)

- [ ] 功能 #8 私有 Note 补全(Pro)
- [ ] 功能 #9 批量 AI 标签精排
- [ ] 多 session 并发优化
- [ ] 评测是否值得扩展到 Pro 用户的默认路径

### 7.4 暂不做

- 任何"FM 完全替代云端"的尝试(见 `01-…` 结论)
- 任何长文 / 联网 / 中文密集场景(见 §3.3)

---

## 八、风险清单

| 风险 | 等级 | 缓解 |
|---|---|---|
| FM 在 macOS 26.1 / 26.2 上 API 微调,破坏 Starcat 兼容性 | 中 | 严格 `@available` 版本判定,失败立刻降级云端 |
| 3B 模型在某些功能上质量太差,招致差评 | 中 | A/B 评测,质量差的功能**直接不上**或**默认云端** |
| FM 占内存(1-2GB),低端 Mac 卡顿 | 中 | Settings 显示占用,提供 "用完即释放" toggle |
| 用户混淆"本地 / 云端"两个后端 | 低 | UX §5.1 强制透明度设计 |
| FM 8K context 不够,切片后语义断裂 | 中 | 切片前做章节检测(按 markdown heading),只在 Starcat 已有 `MarkdownHeadingDemoter` 上加 |
| Apple 突然限制 FM 在第三方 App 的能力 | 低 | 一切以 Apple 官方文档为准,任何"超规"用法立刻撤 |
| FM 中文输出让用户反感 | 中 | 中文密集场景**强制**走云端(§2.2 表) |

---

## 九、关键决策点(等 dong4j 拍板)

1. **MVP 范围确认**: §3.1 的 1/2/5 三项是否一起上?还是先只做 1(搜索扩展)试水?
2. **设置页位置**: FM 设置放进"通用"还是单独 "AI 模型" tab?
3. **图标方案**: `apple.intelligence` SF Symbol 是否在 macOS 15 已有?(需查,可能要用 SF Symbols 5+)
4. **质量评测方案**: 内部 A/B 评测谁来做?需要多少人工评测数据?
5. **隐私承诺文案**: §6.1 的承诺是否需要法务过一遍?(可能不需要,因为 FM 本地本来就是 Apple 背书)
6. **Roadmap 节奏**: §7.1 / §7.2 的拆分是否合理?还是一口气做到 §7.3?

---

## 十、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿:基于 `05-FM 深度研究` + Starcat 现状 + ROI 排序 | Claude |
