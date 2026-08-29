# Apple Foundation Models 在 macOS 26 上跑 Agent 的可行性分析

> **文档定位**: 评估 Apple Foundation Models(FM)框架在 Starcat agent 场景下的可行性。
> **状态**: 技术调研(2026-06-27),未立项。
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md):总览
> - [`../../../../AGENTS.md`](../../../../AGENTS.md):macOS 15+ 最低版本约束
> - [Apple 官方文档](https://developer.apple.com/documentation/foundationmodels)

---

## 一、概述

Apple Foundation Models(下文简称 FM)是 Apple 在 WWDC25 推出的**端侧大语言模型框架**,内建一个约 3B 参数的模型到 Apple Silicon(本地推理、零 API 成本)。它**原生支持 tool calling** 和**结构化输出**(`@Generable`),理论上可以跑 agent。

**问题**: Starcat 最低支持 macOS 15 Sequoia,而 FM **仅在 macOS 26+ 可用**。本文从技术能力、与 Starcat 的适配度、ROI 等角度判断是否要做 FM 集成。

---

## 二、FM 关键能力速查

| 能力 | 是否支持 | 备注 |
|---|---|---|
| 端侧推理 | ✅ | 仅 Apple Silicon(M1+,A17 Pro+) |
| Tool calling | ✅ | 通过 `Tool` 协议,支持 `@Generable` 参数 |
| 结构化输出(Guided Generation) | ✅ | `@Generable struct` 注解,自动约束 |
| 流式响应 | ✅ | `streamResponse(to:)` |
| Agent 循环 | ✅ | 多 tool 自主编排,模型自治 |
| 图片生成 | ❌ | - |
| 微调 | ❌ | 模型固定 |
| 上下文窗口 | ⚠️ | **~8000 tokens**(~6000 词) |
| 速率限制 | ⚠️ | 高并发下会触发本机 rate limit |
| **最低系统** | ❌ | **macOS 26+**(Starcat 不满足) |

---

## 三、与 Starcat 现状的冲突点

### 3.1 系统版本冲突(致命)

- Starcat `AGENTS.md` 明确写:**"macOS 15+ 最低支持"**
- FM 需要 **macOS 26+**
- 结论:**FM 不能作为 Starcat 的默认或必选能力**

可用范围估计(2026-06 视角):
- 2026 年中 macOS 26 装机率仍较低(参考 macOS 14 一年前也只 ~30%)
- 即便到 2027 年中,Starcat 用户群中可能有 30-50% 用 macOS 26+
- 意味着 FM 集成即使做了,**最多只能服务一半用户**

### 3.2 模型能力限制(重要)

| 维度 | FM(3B 本地) | Starcat 默认 AI Proxy(Gemini 2.5 Flash / OpenAI 等) |
|---|---|---|
| 中文能力 | 弱(3B 模型未专门微调) | 强(云端主流模型) |
| 推理深度 | 浅 | 强 |
| 长文理解 | 受 8K 上限制约 | 一般 128K+ |
| 工具调用稳定性 | 一般(小模型常见问题) | 强 |
| 联网 / 实时数据 | ❌ 无 | ✅ |
| 多模态 | ❌ | 部分有(看 provider) |
| 隐私 | ✅ 100% 本地 | ⚠️ 走 API |

### 3.3 关键场景适配度

| Starcat Agent 场景 | FM 适配度 | 说明 |
|---|---|---|
| 替代品推荐 | ⚠️ 中 | 工具调用 OK,但中文推荐语质量堪忧;且需要联网(看 GitHub Trending),FM 没法做 |
| 批量打 tag | ❌ 差 | tag 推荐需要高质量中文,FMs 模型不够 |
| 仓库健康度分析 | ⚠️ 中 | 主要是结构化分析,不依赖中文,FMs 可以胜任;但要联网查 commit 历史 |
| 技术选型 | ❌ 差 | 深度推理 + 长文阅读,FMs 不行 |
| Starred 周报 | ❌ 差 | 强依赖中文写作 + 联网,FMs 不行 |

**结论**: FM **没有一个场景是显著占优的**。它的优势(本地 + 免费)在 Starcat 用户的真实痛点(联网数据 / 中文质量 / 推理深度)上不解决问题。

---

## 四、成本与工作量

### 4.1 集成成本

- SPM 依赖:**零**(FM 是系统框架,直接 `import FoundationModels`)
- Tool 协议适配:已有 `AgentTool` 协议的话,需要写一个 `FMToolAdapter`(~100 行)
- 回退逻辑:必须做"FM 可用 → 用 FM,否则走云端"(增加测试面)
- macOS 版本判定:`if #available(macOS 26, *)` + `SystemLanguageModel.default.isAvailable`
- 用户引导:设置页要加一段"本地模型说明 + 隐私承诺"

**估算**: 200~300 行代码 + 一周左右写 + 测 + 联调

### 4.2 隐性成本

1. **测试矩阵翻倍**: 每次 agent 改动都要在「云端 / FM」两条路径各跑一遍
2. **文档成本**: 用户教育成本——"为什么有些功能在 FM 下表现差"(因为小模型)
3. **客服成本**: 早期用户大概率会报"FM 模式下 agent 答得不好",需要 FAQ 兜底
4. **维护承诺**: macOS 26 之后,Apple 几乎必然要推 27/28,FM API 可能每年都有微调

### 4.3 ROI 估算

| 项 | 数值 |
|---|---|
| 服务用户比例(2026-06) | < 5% |
| 服务用户比例(2027-06 预估) | 30~50% |
| 用户感知价值 | 中(免费 + 隐私,但效果打折) |
| 替代方案(云端 BYOK) | 已有,用户已经习惯 |
| 投入/产出比 | **负** |

---

## 五、风险清单

1. **数据隐私是伪卖点**: Starcat 用户的 stars 库本身就在本地 SQLite,只有 AI 调用时才会出网;FM 替代 AI 调用,只能省掉"AI 调用出网"这一步——但 stars 库还是要走 GitHub API 同步
2. **模型升级依赖 Apple**: 一旦 Apple 调小模型参数或换架构,Starcat 体验会"突然变差",完全无法控制
3. **3B 模型对工具调用的稳定性**: 业界经验,7B 以下模型 tool calling 失败率显著高(尤其是多步链),agent 一旦卡死,用户只能干瞪眼
4. **与 AI Proxy 重复造轮子**: Starcat 已有统一的 AI 调用层(AIClient),FM 进来后变成"两个 AI 后端",架构上需要分叉
5. **Starcat 的 AI 保守策略**: 任何"AI 改用户数据"必须经用户确认,FM 的本地说辞反而模糊了"用户是否真的能审查输出"的边界

---

## 六、建议

### 6.1 短期(2026 年内)**不做**

理由:
- macOS 26 装机率过低,服务用户有限
- 模型能力不能匹配 Starcat 核心场景
- ROI 为负,投入回报不划算
- 自研 agent 编排器(MVP 重点)还不需要 FM

### 6.2 中期(2027 年中)重新评估

触发条件(**任一满足即重评**):
- macOS 26 装机率 > 50%
- Apple 推出 ≥7B 的 FM(传闻中的 "Foundation Models Pro" / Apple Intelligence + Claude)
- FM 的 tool calling 稳定性追平云端模型
- Starcat 用户调研显示"隐私 / 免费"是 Top 3 痛点

### 6.3 如果一定要做,推荐的最小切入点

**只做一个最小化试点**:
- 场景: **「Stars 搜索关键词扩展」** —— 用户输入"笔记",FM 在本地给"note-taking / obsidian / notion / logseq"等同义词
- 工具: 不用 tool calling,只做一次 LLM 推理
- 触发: 设置页加 toggle,默认关
- 价值验证: 收集 6 个月数据,看"FM 路径 vs 云端路径"的用户留存差异

不推荐把 FM 直接接进 agent 主循环(替代品推荐 / 周报 / 技术选型)的任何路径。

---

## 七、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿:基于 WWDC25 公开信息 + Starcat 现状评估 | Claude |
