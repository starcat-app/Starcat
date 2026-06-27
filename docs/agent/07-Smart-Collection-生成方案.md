# Smart Collection 生成(自然语言 → 规则 JSON → 预览)

> **文档定位**: 用 LLM 把"自然语言描述"转成 Starcat 已有 Smart Collection 的规则 JSON,并预览匹配结果。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板。
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`02-替代品推荐-Agent方案.md`](02-替代品推荐-Agent方案.md):共用 `AgentOrchestrator` + `AgentTool` 协议
> - Starcat 已有 Smart Collection 实现(详见代码 `Starcat/Features/SmartCollection/`)
> - [`../CLAUDE.md`](../CLAUDE.md):AI 保守策略(预览 → 确认 → 写入)

---

## 一、用户故事

> 作为 Starcat 用户,我想在 Smart Collection 编辑器里输入"**这周 star 的、用 Swift 写的、star > 1000 的**",agent 立刻帮我:
> 1. 把这句话解析成 Smart Collection 的规则 JSON
> 2. 在我的 stars 库里跑这条规则,显示匹配结果
> 3. 我可以微调规则(点哪条改哪条),再保存

### 1.1 关键差异(与已有功能)

| 维度 | 已有 Smart Collection | 本方案 |
|---|---|---|
| 创建方式 | 手动加 filter 条件 | **自然语言一句话** |
| 学习成本 | 用户必须懂 filter DSL | 0 学习成本 |
| 复杂度上限 | 任意 | 受限于 NL → JSON 的解析能力(经验上 5-8 个条件最佳) |
| 调试 | 直接看 filter | **同时看 JSON + 预览匹配数** |

---

## 二、核心价值

> **"降低 Smart Collection 的创建门槛"**——把"用户懂 DSL"变成"用户懂中文"。

新用户冷启动场景特别有用:导入 200 stars 后想分类,以前必须学 filter,现在一句话搞定。

---

## 三、工具集

### 3.1 工具清单

```
Tool 1: parse_nl_to_smart_collection_rule
  输入:  naturalLanguage(String)
  输出:  SmartCollectionRule (JSON struct,含 conditions 数组 / logic 运算符)
  内部:  调云端 LLM(必须,FM 中文能力不够)
  关键:  @Generable / JSON schema 强约束,杜绝"LLM 输出非法 JSON"

Tool 2: preview_smart_collection_match
  输入:  rule(SmartCollectionRule), limit(默认 20)
  输出:  matchedRepos[](preview)+ totalCount
  复用:  Starcat 已有 SmartCollectionEngine(已有!)

Tool 3: explain_rule_in_chinese
  输入:  rule(SmartCollectionRule)
  输出:  一段中文,解释这条规则在匹配什么
  用途:  用户保存前,确认"AI 理解对了"
```

### 3.2 工具 schema 关键约束

- **`parse_nl_to_smart_collection_rule` 必须严格按 Starcat 已有 rule schema 输出**,否则 `preview_smart_collection_match` 没法跑
- `parse_*` **不**做"模糊推断"——用户没说"按语言",schema 里就不出现 language 条件(避免误伤)
- 单次解析最多 8 个 condition(超出就 reject,提示用户"分两次")

---

## 四、Agent 编排循环

```
[Step 1] system: "你是 Starcat Smart Collection 助手,把自然语言解析为 rule JSON"
[Step 2] user: "这周 star 的、用 Swift 写的、star > 1000 的"
[Step 3] tool_call: parse_nl_to_smart_collection_rule(naturalLanguage=...)
         → rule: { conditions: [{field:"starred_at", op:"within_days", val:7},
                                 {field:"language", op:"eq", val:"Swift"},
                                 {field:"stars", op:">", val:1000}],
                   logic:"AND" }
[Step 4] tool_call: preview_smart_collection_match(rule, limit=20)
         → matched: 3 repos, total: 3
[Step 5] tool_call: explain_rule_in_chinese(rule)
         → "本规则匹配 7 天内 star、Swift 编写、star 数超过 1000 的 repo"
[Step 6] LLM: 综合 step 3-5,给个简短的"我理解对了"的回复
[Step 7] final_answer → UI 渲染(规则 JSON + 匹配预览 + 解释)
```

最大 6 步,通常 3-4 步完成。

---

## 五、UI 落地

### 5.1 入口

**Smart Collection 编辑器顶部加「✨ 用一句话创建」按钮**——比"+ New Collection"更显眼。

### 5.2 弹窗 UI

```
┌─ 用一句话创建 Smart Collection ──────────────────────┐
│                                                       │
│  输入框:                                              │
│  ┌─────────────────────────────────────────────────┐  │
│  │ 这周 star 的、用 Swift 写的、star > 1000 的      │  │
│  └─────────────────────────────────────────────────┘  │
│                                                       │
│  [✨ 生成]                                             │
│                                                       │
│  ─── 解析结果 ───                                     │
│  JSON:                       匹配预览(3 / 3):       │
│  {                             • Alamofire/Alamofire│
│    "logic": "AND",             • apple/swift        │
│    "conditions": [              • vapor/vapor        │
│      {field:"starred_at",                            │
│       op:"within_days",       [📝 解释: 本规则匹配 7│
│       val:7},                  天内 star、Swift 编写、│
│      {field:"language",       star 数超过 1000]      │
│       op:"eq",                                       │
│       val:"Swift"},                                  │
│      {field:"stars",          [💾 保存] [✏️ 编辑规则]  │
│       op:">", val:1000}        [🔄 重新生成] [✕ 取消] │
│    ]                                                  │
│  }                                                    │
└──────────────────────────────────────────────────────┘
```

### 5.3 关键交互

- **「💾 保存」**: 写入 `smart_collection` 表(已有)
- **「✏️ 编辑规则」**: 跳到原生 Smart Collection 编辑器,用户可手改 filter(给高级用户退路)
- **「🔄 重新生成」**: 重跑 agent run(同样配额)
- **匹配 0 条**: 弹 toast "没匹配到,试试放宽条件?"(不阻断)

### 5.4 错误处理

| 错误 | UI 表现 |
|---|---|
| LLM 输出非法 JSON | 弹 toast "AI 解析失败,请换种说法",**不**扣配额 |
| 解析出 > 8 个 condition | 弹 toast "条件太多,请简化" |
| 用户输入含 prompt injection(试图改 system prompt) | 走现有 AI Proxy 风控,降级到云端 / 拒绝 |
| 预览 0 匹配 + 看起来合理 | 提示"没匹配到,这是结果,要不要保存空集合?" |

---

## 六、数据闭环

### 6.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `smart_collection` 表 | 保存生成的集合 |
| `SmartCollectionEngine` | 跑匹配规则(已有) |
| `stars` / `repo` 表 | 数据源 |
| `AIClient` / AI Proxy | 调 LLM |
| `EntitlementGate` + `quota` | 配额控制 |

### 6.2 新增 `nl_smart_collection_history` 表(可选,仅做分析)

```sql
CREATE TABLE nl_smart_collection_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    raw_input TEXT NOT NULL,
    parsed_rule_json TEXT NOT NULL,
    match_count INTEGER NOT NULL,
    user_saved INTEGER NOT NULL,        -- 0 / 1
    created_at INTEGER NOT NULL
);
```

**为什么需要这张表**:
- 收集"用户怎么描述集合"的数据,反哺 LLM prompt 优化
- 统计"自然语言创建"的转化率(创建后用户是否保存 / 是否编辑后保存)
- 不存 LLM 思考过程(走 `AIDebugLogger`)

### 6.3 不引入新表的设计取舍

- 不存"生成的 Smart Collection 完整数据"——直接走 `smart_collection` 表
- 不存"用户编辑历史"——已有 Smart Collection 自带 updated_at

---

## 七、付费与配额

| 用户档 | 体验 |
|---|---|
| **Free** | 每日 5 次 NL 创建;解析后**必须**手动点保存;单集合规则上限 5 个 condition |
| **Pro** | 不限次数;解析后**可**自动保存(批量);规则上限 8 个 condition;支持保存为「模板」 |

- 单次 run 配额消耗: **1 quota**(聚合为一次 LLM 编排)
- 配额扣减: 解析成功 + 预览成功 = 1 quota;解析失败 = 0 quota

---

## 八、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| `parse_nl_to_smart_collection_rule` Tool | 新增 | 小(核心是 prompt + schema) |
| `preview_smart_collection_match` Tool | 极小(包装已有 `SmartCollectionEngine`) | 极小 |
| `explain_rule_in_chinese` Tool | 新增 | 极小 |
| 「✨ 用一句话创建」入口按钮 | 新增 | 极小 |
| 弹窗 UI(含 JSON 编辑 + 预览 + 解释) | 新增 | 中 |
| Smart Collection rule JSON schema 文档化 | 新增 | 小(已有 schema,只需输出) |
| 单测(各种 NL 输入边界) | 新增 | 中 |
| i18n 词条(`smartcollection.nl.*`) | 新增 | 小 |
| `docs/工程进度/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: 小。**最大难点是 NL → rule schema 的 prompt**,需要 50-100 个真实样本迭代。

---

## 九、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| LLM 输出的 rule schema 字段名错(比如写 `language_eq` 而不是 `language` + `op:eq`) | 高 | 严格 JSON schema 约束 + 输出后客户端校验;失败降级到"AI 解析失败" |
| 用户描述太模糊("好的项目") | 中 | 强制要求至少 1 个具体字段(star 数 / 时间 / 语言 / topic);否则引导用户补充 |
| Prompt injection(用户输入里藏指令) | 中 | NL 输入只走 parse tool,**不**进 system prompt;LLM 看不到用户原始输入(只看到 tool result) |
| 用户保存一个"每次都匹配 0 条"的空集合 | 低 | 0 匹配 + 用户主动保存 → 允许(用户可能就是要这种"理想列表") |
| 多语言混杂(中英混) | 低 | rule JSON 字段值统一英文;UI 显示再翻译 |
| 配额的"重生成"被滥用 | 中 | 重生成同样扣配额;Pro 才有自动保存 |

---

## 十、后续可拓展方向

1. **语音输入**:macOS 26+ Speech framework + FM 转写,NL 输入零打字
2. **逆向**: 从已有 Smart Collection 生成"自然语言描述"(给分享用)
3. **集合组合**: "把 A 集合和 B 集合的并集,排除 C 集合"
4. **定时重新匹配**: 集合每天自动重跑,新 star 自动入集合
5. **分享模板**: 用户保存的"自然语言 → rule"模板可分享给社区

---

## 十一、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿 | Claude |
