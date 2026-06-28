# Starcat Companion（Chrome 插件）总体方案

> **状态**: 设计中（2026-06-12，待 dong4j 拍板施工）
> **依赖**: R-04 后端聚合表 `github_repos`（[`21-weekly-api-后端3源聚合改造.md`](./21-weekly-api-后端3源聚合改造.md)）落地后插件能力可全量铺开；MVP 不强依赖 R-04
> **影响范围**: 新建 Chrome 插件项目 + Starcat App 内嵌本地 HTTP 服务（小改动）+ 已有 deep link 路由扩展
> **不影响**: 4 个后端 Go 服务（trending / weekly / sharing / wiki）、客户端 GRDB schema、客户端核心架构（UnifiedRepoRow / RepoDetailScaffold / StarredRegistry）
> **本文档不涉及**: 代码细节、文件清单、PR 切分、UI mock — 这些在施工阶段再补
> **关联**:
> - 原始需求：[`docs/需求讨论/chrome插件-需求初稿.md`](../需求讨论/chrome插件-需求初稿.md)（v0 初稿，本设计是其结合现状的升级版）
> - [`16-活动页设计.md`](./16-活动页设计.md)（Activity 8 个具体分类，浏览器采集复用同骨架）
> - [`18-三场景共用架构.md`](./18-三场景共用架构.md)（envelope / Bearer / UnifiedRepoRow / RepoDetailScaffold / StarredRegistry，**本设计沿用**）
> - [`21-weekly-api-后端3源聚合改造.md`](./21-weekly-api-后端3源聚合改造.md)（R-04 主表 `github_repos` + `source_types` 数组，浏览器采集作为新 source 接入）

---

## 文档版本演进

| 版本 | 日期 | 主要调整 | 触发人 / 触发原因 |
|---|---|---|---|
| v1.0 | 2026-06-12 | 把原始需求 `chrome插件-需求初稿.md` 升级为可落地设计：① 结合 Starcat 现状重定位（"Starcat 私人空间在浏览器里的镜像 + 最低摩擦的采集通道"）；② 五项 MVP 功能 F1~F5；③ 双向通信通道（URL Scheme + 本地 HTTP）；④ R-04 主表 `source=clip` 接入路径；⑤ 能力边界（严禁插件碰 token / 调 GitHub API / 跑 AI） | 原始需求是在不知 Starcat 现状的前提下写的，存在大量越界（插件做 AI / 独立 Inbox 表 / Research Session 隐私敏感）；本版按 Starcat 已上线 8 分类 Activity + R-04 聚合表 + StarredRegistry + BYOK AI 的现状重写 |

---

## 0. TL;DR

**原始方案** 把插件设计成"GitHub 浏览的另一个增强工具 + AI 助手"；
**本方案** 把插件收敛为：

> **Starcat 私人空间在浏览器里的镜像 + 一条最低摩擦的采集通道**。

一切 AI / 数据 / 同步重活留在 Starcat App，插件只做两件事：

1. **正向（浏览器 → App）**：把当前 GitHub repo / 选中文本 / 长讨论页一键送进 Starcat（采集到 R-04 主表 `source=clip`、追加到笔记、触发 AI 摘要 / 翻译）。
2. **反向（App → 浏览器）**：把 Starcat 内部的私人元数据（标签 / 笔记首行 / 阅读状态 / Release 订阅 / AI 摘要首句）实时叠加到 GitHub 页面上。

**最强差异化**：反向链路（私人元数据浏览器投射）是同类工具（Stars Manager / Star Track / GitHub 官方 List）**没有任何一个**做的事，是 dong4j 多年打磨的「整理 / 理解 / 找回 / 评估」核心价值在浏览器侧的天然延伸。

**MVP 范围**：5 个功能（F1~F5），3 周内可发 Chrome Web Store 内测，零新增数据表，零新增 Starcat 视图。

---

## 1. 背景与目标

### 1.1 原始需求

`docs/需求讨论/chrome插件-需求初稿.md`（1041 行 v0 初稿）。在不掌握 Starcat 现状的前提下写出，存在以下越界：

1. 提议新建独立 "Starcat Inbox / Knowledge / Clips" 模块 —— 但 Starcat 已经有 Activity 聚合页 8 个具体分类，且 R-04 正在把所有外部源合并到主表 `github_repos`，再立 Inbox 表是重复造轮子。
2. 让插件做 AI 摘要 / PR 总结 / Release 解释 —— 但 Starcat 已有完整 BYOK AI 链路（18+ provider / 流式摘要 / `ai_summaries` 表 / README 翻译 / 自动后台整理），插件再配一份 AI = 体验割裂。
3. 列入 "浏览历史智能归类" —— 隐私敏感，违反 Starcat「保守 AI」原则（"AI 给建议，用户确认后才写入"）。
4. 列入 "Research Session" —— 概念漂亮，但需要浏览历史采集 + 决策记录模型 + 跨源聚合 UI，MVP ROI 不足。
5. 几乎没有提反向链路（App → 浏览器）—— 但这恰恰是浏览器插件**唯一无法被 App 替代**的能力。

### 1.2 与 Starcat 现状的关系

| Starcat 已有能力 | 插件如何利用（不重复造轮子） |
|---|---|
| Activity 聚合页 8 分类（含 weekly / discovery） | 浏览器采集走 `source=clip` 进同一主表，落到 Activity / Discovery 分类骨架 |
| R-04 主表 `github_repos` + `source_types` 数组 | 插件采集天然作为新 source，零架构成本 |
| `RepoDetailScaffold` + `UnifiedRepoRow` 4 详情页同构 | deep link 唤起后直接落到 Scaffold，不需要为采集源单独设计视图 |
| `StarredRegistry`（@MainActor @Observable 单一信任源） | 反向链路状态镜像直接消费 registry，秒级一致 |
| BYOK AI 链路（`RepoAIInsightService` / `ReadmeTranslationService`） | 插件**只触发**，所有推理在 App 内 |
| 4 个后端服务统一 envelope + Bearer + `/api/v1/ping` | 本地 HTTP 服务沿用同款契约（Swift 版平移），降低认知负担 |
| AES-GCM 加密本地凭证 | 插件**永远不接触** GitHub Token / AI Key |
| 私人数据 4 套（tags / repo_notes / repo_status / release_subscriptions） | 反向链路投射的全部"原料"已就绪 |

### 1.3 目标

1. **MVP（V0.1，3 周）**：让用户在浏览器里**立刻**感受到 Starcat 价值——不开 App 也能看到 GitHub 项目的私人元数据；右键就能把当前内容送进 Starcat。
2. **复用现有架构**：零新增 GRDB 表、零新增视图、零新增后端服务；只新建 1 个 Chrome 插件项目 + Starcat App 内嵌 1 个本地 HTTP 服务模块。
3. **能力边界明确**：插件只做"事件触发器 + 视图镜像"，AI / GitHub API / 数据持久化全留 App。
4. **降级稳健**：Starcat App 关闭时，插件自动降级为"只能采集"（deep link 单向），不报错不阻塞用户浏览。
5. **拉新与黏性双轮**：Chrome Web Store 是天然引流入口；让用户每天看 GitHub 即感受 Starcat 价值，不必"想起来用"。

### 1.4 非目标

1. **不做插件内 AI 对话** —— 复制 BYOK 配置 = 体验割裂。所有 AI 触发都走 deep link 回 App。
2. **不做完整网页正文抽取** —— 解析复杂、站点差异大，低 ROI。
3. **不做浏览历史自动归类 / 智能分析** —— 隐私敏感，违反 Starcat「保守 AI」原则。
4. **不做 Native Messaging** —— URL Scheme + 本地 HTTP 双通道已足够，不值得装本地辅助程序。
5. **不做 Firefox / Safari 扩展（V0.1）** —— Safari 需要 Xcode 项目化；Firefox MV3 兼容仍在演进；MVP 仅 Chromium 系（Chrome / Edge / Arc / Brave）。
6. **不做 Research Session（V0.1/V0.2）** —— 留 V0.3 评估，先观测 V0.1 用户行为。
7. **不做插件内多设备 / 多 Starcat 实例切换** —— MVP 单实例对接，多实例 V0.3 评估。
8. **不接入 Show HN 之外的发现源** —— 后端 Discovery 已专属 Show HN，插件 V0.3 才考虑跨站采集（HN 评论 / Reddit / 技术博客）。

---

## 2. Starcat 现状摘要（设计前提）

只列对插件设计有判定影响的事实，省略与浏览器侧无关的细节。

| 维度 | 现状 | 对插件设计的影响 |
|---|---|---|
| 三大入口 | Sidebar 已分 **Manage / Trending / Activity**（不是原方案设想的 Search） | 插件不需要再造 "Inbox / Research" 概念，直接喂给已有的 Activity 体系 |
| Activity 聚合页 | 已上线 8 个具体分类：`announcement / release / star / repository / following / suggestion / weekly / discovery` | 浏览器采集直接走 `Activity` 既有信道，不另立分类 |
| 后端 4 个 Go 服务 | trending / weekly / sharing / wiki，统一 envelope + Bearer Auth + `/api/v1/ping` | 插件本地 HTTP 服务可直接复用同一套契约（envelope / Bearer），不需要新协议 |
| R-04 聚合表（设计中） | 把 3 张孤岛表合并为 `github_repos` 主表 + 4 附表，主键 `gh_repo_id`，对外 1 个 `GET /api/v1/repos` | **关键**：插件采集的"浏览器现场"作为新的 `source_type = "clip"` 喂进同一主表，零架构成本 |
| StarredRegistry | 跨场景实时单一信任源（`@MainActor @Observable`） | 反向链路查"当前 repo 是否已 star"直接复用此 registry |
| 详情页骨架 | `RepoDetailScaffold` + `UnifiedRepoRow` 4 详情页同构 | 插件唤起 deep link 时无需为采集源新增视图，落到现有 Scaffold |
| BYOK AI 链路 | 18+ provider、流式摘要、`ai_summaries` 表、README 翻译、自动后台整理 | **插件不要再做 AI**，统一交回 App 跑 |
| Repo 私人数据 | tags / repo_notes / repo_status / release_subscriptions 4 套已就绪 | 反向链路"私人增强层"原料齐备，只缺一个外送通道 |
| Token 存储 | AES-GCM 本地加密文件（不走 macOS Keychain） | 插件**严禁**接触任何 token，token 永远只在 App 内 |
| Deep Link 设计 | R-04 主键 `gh_repo_id` 已稳定；客户端已规划支持 deep link 路由 | 插件触发 → App 路由解析 → 进入 Activity / Manage / Trending 详情页（路径已通） |

---

## 3. 对原始方案的取舍

把原始 12 章方案逐项过了一遍，留下能落地、能差异化、能复用现有架构的部分，砍掉伪需求或越界部分。

### 3.1 保留并强化（核心）

| 原方案点 | 调整 |
|---|---|
| GitHub Repo 一键发送 → Starcat | 保留为 MVP F2（功能编号见 §7） |
| 右键选中文本送给 Starcat | 保留为 MVP F3，但**只走"追加到 repo_notes"** 一个明确动作（不做"Ask Starcat"那种发散 prompt） |
| GitHub 页面注入 Starcat 浮层按钮 | 保留为 MVP F4，但限制为 **4 个固定动作**（在 Starcat 中打开 / 采集 / 追加笔记 / 复制 deep link），不展开成入口大列表 |
| 跨网页保存为 Starcat 资源 | 保留方向，但**不开 Inbox / Knowledge / Clips 模块**，直接喂回 R-04 主表 `source=clip`，复用 Activity 8 分类骨架 |

### 3.2 重新定位（关键改动）

| 原方案点 | 调整后 | 理由 |
|---|---|---|
| Starcat Inbox（独立模块） | **不另开 Inbox**，直接复用 R-04 主表 `github_repos`，`source_type = "clip"` | R-04 主表方案已能覆盖跨源去重 + 时间线，再立一张 inbox 表与设计反向 |
| Issue / PR / Release AI 总结 | 插件**只触发**，App 内执行；结果落 `ai_summaries` 表后 App 推送系统通知 | 复用已有 BYOK 链路 + Prompt 管理，不在插件配 AI |
| Repo AI 速览卡片（重新算速览） | 不展示新算的速览，**只展示 Starcat App 已缓存的私人元数据**（tags / notes_excerpt / status / release_subscribed / latest_ai_summary_excerpt） | 浏览器侧不应再调任何 GitHub API（用户在 GitHub 页面已经能看到原始数据）；强项是叠加私人信息 |
| Research Session | **MVP 不做**，留 V0.3 评估 | 需要浏览历史采集 + 决策记录模型，隐私敏感 + 收益不确定 |
| Repo 对比入口 | **MVP 不做**，留 V0.3+ | R-04 聚合表上线后再考虑 "浏览器收集候选 → App 对比页"（属于 P2 AI 高级"对比报告"功能的浏览器入口） |

### 3.3 直接砍掉（V0.1 / V0.2 均不做）

| 项 | 砍掉理由 |
|---|---|
| 完整网页正文抽取 | 解析复杂、网站差异大、低 ROI |
| 浏览历史自动分析 / 智能归类 | 隐私敏感，违反 Starcat「保守 AI」原则 |
| Native Messaging | URL Scheme + 本地 HTTP 双通道已足够，没必要装本地辅助程序 |
| 插件内 AI 对话 | 复制 BYOK 配置 = 体验割裂；用户的 API Key 安全边界也变模糊 |
| 自动注入大量 GitHub UI（Issue 标题区按钮 / Release 页按钮 / 源码页按钮等） | 与 GitHub DOM 结构强耦合，维护成本高；统一收敛到一个浮层（F4） |
| 安全风险提醒（依赖归档 / 维护停止 / 安全公告） | 这是 Starcat App 的 Release 订阅 + P2 项目健康度评分的范畴，不是浏览器侧职责 |

---

## 4. 核心定位与三个闭环

### 4.1 定位

> **Starcat Companion = 浏览器现场 ↔ Starcat 私人空间 的双向桥**

差异化的关键在**反向链路**——这是原方案完全没提，但价值最大的一块。

### 4.2 闭环 1：状态镜像（反向，最强差异化）

```
GitHub 页面（任意 repo / issue / release）
    ↓
插件 content script 扫描 owner/repo
    ↓
fetch http://127.0.0.1:5051/local/v1/state?fullname=owner/repo
    ↓ （Bearer Auth）
Starcat App 本地 HTTP 服务返回私人元数据
    ↓
GitHub 页面 README 上方注入"私人胶囊"
（已 star / 标签 chips / 笔记首行 / 阅读状态 / Release 订阅 / 最近 AI 摘要首句）
```

**解决的痛点**：

> 「我两个月前是不是 star 过这个？打了什么标签？以前评估过吗？AI 帮我写过摘要吗？」

**为什么是浏览器独有**：用户在 GitHub 页面看 README 的当下，App 是后台进程。让用户切到 App 找私人元数据 = 50% 概率懒得切 = 信息丢失。

### 4.3 闭环 2：现场采集（正向）

```
浏览器看到值得记录的内容
    ↓
一键浮按钮 / 右键菜单触发 deep link
    ↓
starcat://capture?fullname=...    或
starcat://capture-note?fullname=...&text=...
    ↓
Starcat App 路由解析
    ↓
入主表 github_repos（source_types += ["clip"]）
落 repo_notes（追加 "> 来自浏览器：URL\n选中文本"）
跳转详情页
```

**解决的痛点**：

> 「记录耗时太大，每次都要 Cmd+Tab 切回 Starcat 找搜索框输入」

**与 R-04 主表对齐**：`source=clip` 与 weekly / zread / discovery / trending 并列，Activity 聚合页天然能展示，零新增 UI。

### 4.4 闭环 3：导航触达（正向）

```
浏览器看到长 Issue / PR / Release Notes
    ↓
点"Starcat 总结此页 / 翻译此 README / 解释升级风险"
    ↓
starcat://summarize?fullname=...&kind=issue|pr|release&url=...   或
starcat://translate-readme?fullname=...
    ↓
App 用 BYOK 链路（RepoAIInsightService / ReadmeTranslationService）跑
    ↓
完成后系统通知 + 详情页可见结果（已有 RepoAIInsightPanel 路径）
```

**解决的痛点**：

> 「GitHub 长 Issue / PR / Release Notes 阅读疲劳；切 App 跑 AI 太重」

**与已有 AI 体系对齐**：BYOK Provider Profile / Prompt 模板 / `ai_summaries` 缓存全部不动，只新增几个 prompt template（issue / pr / release-risk）。

---

## 5. 能力边界

为防止"插件做太多 → 与 App 体验分裂 → 维护成本爆炸"，先把边界写死。

### 5.1 角色职责矩阵

| 角色 | 职责 |
|---|---|
| **Chrome 插件** | ① 识别 GitHub / HN / 技术博客 URL（通过 content script 解析 location）<br>② 提取当前 owner/repo / 选中文本 / 当前 URL<br>③ 通过本地 HTTP 查询 Starcat 私人状态<br>④ 唤起 deep link（5 个 action）<br>⑤ GitHub 页面叠加私人元数据胶囊（F1）<br>⑥ 浏览器图标角标显示状态点（F5）<br>⑦ 提供 popup（toolbar 点击）+ 浮按钮（GitHub 页面注入）+ 右键菜单 三种交互入口 |
| **Starcat App** | ① 维护本地 HTTP 服务（`/local/v1/ping` + `/local/v1/state` + V0.2 起 `/local/v1/capture`）<br>② 解析 deep link 5 个 action 并路由<br>③ 入 R-04 主表 / 写 repo_notes / 触发 BYOK AI 链路 / 触发 README 翻译<br>④ 推送系统通知（AI 摘要完成 / 翻译完成）<br>⑤ 设置页提供"Starcat Companion"分组（端口号、Bearer Token 显示与重置、连接状态指示） |
| **后端 4 服务** | 同既定职责（trending / weekly / sharing / wiki + R-04 聚合）；**插件不直接与后端通讯**，所有路径走"插件 → App → 后端" |

### 5.2 严禁项（写入 manifest / Code Review checklist）

| 严禁 | 理由 |
|---|---|
| ❌ 插件代码中出现任何 GitHub Token 字符串 / Bearer Token（除 Companion Token）/ AI API Key | Token 永远只在 App 加密文件里 |
| ❌ 插件 fetch `https://api.github.com/*` | 用户 API 配额不属于插件；GitHub API 调用全部由 App 走 |
| ❌ 插件代码中出现任何 LLM provider 域名（openai.com / anthropic.com / openrouter.ai 等）的 fetch | AI 推理永远在 App 内 |
| ❌ 插件持久化用户私有数据（标签 / 笔记 / 状态 / star 列表） | 私有数据永远只在 App 加密 SQLite 内；插件只做"读 + 渲染"瞬态展示，不缓存超过 60s |
| ❌ 插件采集 / 上报浏览历史 | 隐私敏感；只在用户**主动**触发动作（点击 / 右键）时读取当前 tab URL |
| ❌ 插件改写或拦截 GitHub 页面原有功能 | 只**追加**胶囊，不替换、不隐藏、不劫持 GitHub 自带按钮 |

### 5.3 降级策略

| 场景 | 表现 |
|---|---|
| Starcat App 未启动（本地 HTTP 5051 不可达） | F1 / F5 自动降级（不显示胶囊 / 角标灰色）；F2 / F3 / F4 仍可触发 deep link（macOS 自动唤起 App） |
| Companion Token 错误 / 被重置 | 浮按钮提示"请到 Starcat → 设置 → Companion 复制最新 Token" |
| 插件 + App 版本不匹配 | `/local/v1/ping` 返回 `schema_version`；插件检查到不兼容时浮提示"请升级 Starcat App / 插件" |
| 用户配置的端口与本机其他应用冲突 | App 启动时探测 5051~5060 范围内可用端口，写入 `companion.token` 一并持久化端口号；插件设置页读端口 |

---

## 6. 双向通信通道

这是整个方案唯一的"基建技术决策点"，必须先选定。

### 6.1 正向链路（浏览器 → App）：URL Scheme

完全采用原方案 §4.1 / §8.3(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 的思路，但**收敛到 5 个 action**，与 R-04 主表 + 4 详情页骨架对齐：

| Deep Link Action | 触发场景 | App 端落点 |
|---|---|---|
| `starcat://repo?fullname=owner/repo` | "在 Starcat 中打开" | 直接进 Manage / Activity / Discovery 详情页（按是否 starred 走分支，复用 RepoResolverChain 现成路径）|
| `starcat://capture?fullname=owner/repo&source=clip` | "采集到 Starcat" | 入 R-04 主表 `github_repos`（source_types 追加 `clip`），跳详情页 |
| `starcat://capture-note?fullname=...&text=<urlencoded>` | 右键"追加到笔记" | 走 `RepoNoteRepository.append`，附加 "> 来自浏览器：…\n{text}" |
| `starcat://summarize?fullname=...&kind=issue|pr|release&url=...` | "Starcat 总结此页" | App 触发 BYOK AI 链路，复用 `RepoAIInsightService` 路径，结果落 `ai_summaries` 表 |
| `starcat://translate-readme?fullname=...` | "Starcat 翻译此 README" | 复用已有 `ReadmeTranslationService` 路径 |

> **不要**给每个动作单独定义 URL Scheme（如 `starcat://issue`、`starcat://release`、`starcat://clip`）。统一用 5 个 action + 参数化，保持 App 路由表小且易测。
>
> **参数规范**：`fullname` 永远使用 `owner/repo` 字面量（GitHub 显示形态），App 端用 case-insensitive 规则匹配本地 DB；URL / 选中文本必须用 `encodeURIComponent`，不允许直接拼接。

### 6.2 反向链路（App → 浏览器）：本地 HTTP 服务

为支持「状态镜像」闭环，必须有一条"浏览器能问 App、App 立刻答"的路径。可选方案对比：

| 方案 | 优点 | 缺点 | 评分 |
|---|---|---|---|
| **A. App 启 `127.0.0.1:5051` HTTP 服务（Bearer Auth）** | 与现有 4 个后端服务契约一致；插件用浏览器原生 `fetch` 即可；不依赖系统级配置；Bearer 共享密钥 | 占用一个本地端口；需要 App 启动时拉起 server | ⭐⭐⭐⭐⭐ |
| B. Chrome `chrome.nativeMessaging` | 系统级安全模型 | 需要装本地辅助程序 + manifest 注册；MVP 复杂度过高 | ⭐⭐ |
| C. WebSocket / SSE 推送 | 实时性最好（App 端状态变化能 push） | 比 HTTP fetch 复杂；MVP 用不上（用户切 tab 时 fetch 一次足够） | ⭐⭐⭐ |
| D. 共享文件 / pasteboard | 实现简单 | Chrome 插件读不到本地任意文件（沙箱） | ❌ |

**推荐方案 A**，理由：

1. Starcat 已经有 4 个独立 Go 服务的 envelope / Bearer / `/api/v1/ping` 模板，App 内嵌一个 Swift 版本几乎是把模板平移（用 SwiftNIO 或 Network.framework + URLSessionStreamTask 都可以）
2. 插件只是 `fetch('http://127.0.0.1:5051/local/v1/state?...')`，零额外 SDK
3. App 关闭则端口不通 → 插件 fetch 失败 → 自动降级（不显示私人胶囊，但保留 deep link 采集），这恰好就是我们想要的降级行为
4. Bearer Token 由 App 首次启动生成（写入 `~/Library/Application Support/Starcat/companion.token`，与 `credentials.json` 同目录），用户在「设置 → Companion」里可看可重置；插件首次安装时引导用户复制粘贴

### 6.3 本地端点最小集

#### V0.1 仅 2 个端点

| 端点 | 用途 | 备注 |
|---|---|---|
| `GET /local/v1/ping` | 健康检查 + schema_version 协商 | 与 4 后端 ping 同语义；插件首次安装握手用 |
| `GET /local/v1/state?fullname=owner/repo` | 取该 repo 的 starred / tags / notes_excerpt(≤120 字符) / status / release_subscribed / latest_ai_summary_excerpt(≤200 字符) | **单接口聚合返回**，避免插件多次请求；excerpt 截断减少敏感数据出窗口 |

#### V0.2 起增量

| 端点 | 用途 |
|---|---|
| `POST /local/v1/capture` | 与 `starcat://capture` 等价但走本地 HTTP，省去拉起 App 的成本（响应 toast / 仅在 App 已运行时使用） |
| `POST /local/v1/note/append` | 与 `starcat://capture-note` 等价 |
| `GET /local/v1/state-batch?fullnames=a/b,c/d,...` | 批量查询（trending 页面增强用，一次拿 25 项状态） |

### 6.4 Manifest 权限申请要点（V0.1）

| 权限 | 用途 | 说明 |
|---|---|---|
| `host_permissions: ["http://127.0.0.1:*/"]` | 反向链路 | 限定本机回环，不申请通用 `<all_urls>` |
| `host_permissions: ["https://github.com/*"]` | F1 / F4 / F5（GitHub 页面注入 + 状态镜像） | 仅限 github.com，不申请 `*://*.github.com/*` 避免触发 enterprise GHE 等场景 |
| `contextMenus` | F3（右键菜单） | 仅在 GitHub 页面启用 |
| `storage` | 保存 Bearer Token + 用户偏好（如关闭某些胶囊） | 仅 chrome.storage.local，不同步 |
| `activeTab` | 读取当前 tab URL | 配合用户主动点击触发，不滥用 |

> **不申请**：`tabs`（避免被识别为可读所有 tab 的"重权限"插件）、`webRequest`、`webNavigation`、`history`、`downloads`、`<all_urls>`。Chrome Web Store 审核对这些权限敏感，多一项申请就多一道审核卡点。

---

## 7. MVP（V0.1）功能清单

> **目标**：3 周内可发 Chrome Web Store 内测，让用户立刻感受到"浏览器里的 Starcat"。

### 7.1 必做 5 项

#### F1：GitHub repo 状态镜像胶囊（最强差异化）

**浏览器侧表现**：

- 用户打开 `github.com/{owner}/{repo}` 任意子页面（含 README / Issues / PRs / Releases / Code）
- 页面 README 标题正上方注入一张胶囊（容器选择 README 上方而非 About 区右上，DOM 结构最稳定）
- 胶囊内容（横向单行，可折叠）：
  - 左：✓ 已 star 标识（绿色）/ ☆ 未 star 标识（灰色）
  - 中：标签 chips（≤3 个，溢出折叠成 +N）
  - 中：阅读状态徽章（未读 / 在读 / 在用 / 废弃）
  - 中：Release 订阅徽章（含未读数）
  - 右：笔记首行（≤80 字符截断，hover 显示完整）
  - 右：最近 AI 摘要首句（≤80 字符截断，hover 显示完整）
  - 最右：齿轮按钮（折叠胶囊 / 跳转设置）

**App 侧改造**：

- 实现 `GET /local/v1/state` 端点
- 字段映射：`isStarred`（StarredRegistry）/ `tags`（RepoTagRepository）/ `notesExcerpt`（RepoNoteRepository.find().content 前 120 字符）/ `status`（同表）/ `releaseSubscribed` + `unreadReleaseCount`（release_subscriptions 表）/ `latestAISummaryExcerpt`（ai_summaries 表，summary_json 解析后取 oneLineSummary 前 200 字符）

**关键设计点**：

- 胶囊**只展示已有数据**，不触发任何 API 调用 / AI 推理
- 缓存策略：插件 content script 内存缓存 `state` 60s（同一 tab 切 PR / Issue 子页面时不重复 fetch）；切到不同 repo 立即重 fetch
- 用户可在插件设置里关掉特定胶囊字段（如不想显示笔记首行）
- 隐私：胶囊数据**不离开浏览器进程**（不 sync、不上传），关闭 tab 即清理

#### F2：一键采集到 Starcat

**浏览器侧表现**：

- 在 GitHub repo 页面 toolbar popup（点击插件图标）显示"采集到 Starcat"主按钮
- 浮按钮（F4）展开后也包含此动作
- 点击触发 `starcat://capture?fullname=owner/repo&source=clip`

**App 侧改造**：

- 路由解析 `starcat://capture` action
- 入 R-04 主表 `github_repos`：
  - 若该 `gh_repo_id` 已存在：`UPDATE source_types = source_types ∪ {'clip'}, last_seen_at = NOW()`
  - 若不存在：先调一次 GitHub `/repos/{o}/{r}` enrich，写入主表 + `source_types = ['clip']`
- 自动跳转详情页（已有 RepoDetailScaffold）

**关键设计点**：

- 已 star 的 repo 也可采集，等于"标记最近浏览过"，`last_seen_at` 跟着更新；语义上不会重复创建
- 网络不可达时 enrich 失败：`source_types = ['clip']` 仍写入，等下次 sync 自动 enrich

#### F3：右键选中文本追加到 repo_notes

**浏览器侧表现**：

- 仅在 `github.com/{owner}/{repo}/*` 页面 + 用户选中文本时，右键菜单出现 "Starcat：追加到笔记" 项
- 点击触发 `starcat://capture-note?fullname=...&text=<urlencoded>`
- 选中文本超过 2000 字符时截断 + 提示

**App 侧改造**：

- 路由解析 `starcat://capture-note` action
- 调 `RepoNoteRepository.find(repoId:)` → 若不存在，先建空 note → `append("\n\n> 来自浏览器：{当前页 URL}（YYYY-MM-DD HH:MM）\n{选中文本}")`
- 后台静默完成（不强制跳详情页），系统通知提示"已追加到 owner/repo 笔记"

**关键设计点**：

- 必须本地 DB 已有该 repo（已 star 或已 capture），否则提示"请先采集此 repo 再追加笔记"
- 追加格式固定（带来源 URL + 时间戳），方便用户后续检索
- 不做 AI 摘要，纯文本追加

#### F4：GitHub 页面浮层（4 按钮）

**浏览器侧表现**：

- GitHub repo 页面右下角浮一个 Starcat 图标按钮（24×24，半透明，不抢视觉）
- Hover 展开 4 项菜单：
  - ① 在 Starcat 中打开 → `starcat://repo`
  - ② 采集到 Starcat → `starcat://capture`
  - ③ 追加笔记（点击弹文本框，输入后追加）→ `starcat://capture-note`
  - ④ 复制 deep link（拷贝 `starcat://repo?fullname=...` 到剪贴板，便于发给同事）

**App 侧改造**：仅 ① ② ③ 走 deep link，无新改动。

**关键设计点**：

- 浮按钮位置可拖拽 + 记忆（chrome.storage.local 持久化）
- 浮按钮可被用户**永久隐藏**（设置开关），隐藏后只通过 toolbar popup 入口
- 不在 Issue / PR / Release 页面显示（避免与 GitHub 页面元素抢位置）

#### F5：浏览器图标角标

**浏览器侧表现**：

- 当前页是 GitHub repo 时，扩展图标右下角显示状态点：
  - 🟢 已 star（无未读 release）
  - 🔴 已 star + 有未读 release（角标显示数字）
  - ⚪ 未 star
  - 🚫 Starcat App 未启动（灰色）
- 当前页非 GitHub repo 时，无角标

**App 侧改造**：复用 F1 同一接口。

**关键设计点**：

- "未读 release" 计数 ≤9 显示数字，>9 显示 9+
- 角标是用户感知最强、技术成本最低的状态镜像形式

### 7.2 不做（V0.1 不做）

- Issue / PR / Release 总结（V0.2）
- README 翻译（V0.2，待 §12(详见 `docs/6-发版与上架/v1-上架信息准备.md`) Q2 拍板可提到 V0.1）
- Trending 页面增强（V0.2）
- 跨站采集 HN / Reddit / 博客（V0.3）
- Repo 对比候选（V0.3+）
- Research Session（评估）

---

## 8. 路线图（V0.2 / V0.3）

| 阶段 | 功能 | 依赖 | 预估工期 |
|---|---|---|---|
| **V0.2** | F6：Issue / PR / Release Notes 一键 Starcat 总结 | 已有 `RepoAIInsightService` 路径，扩展 prompt template 即可 | 1 周 |
| V0.2 | F7：Release 升级风险解释 | 同 F6，prompt 不同 | 0.5 周 |
| V0.2 | F8：Trending 页面行内增强（github.com/trending 每行叠 ✓ 标记 + 标签） | 复用 `/local/v1/state-batch` 批量端点 | 0.5 周 |
| V0.2 | F9：插件设置页内置「测试 Starcat 连接」（仿 R-03 单步 ping） | 复用 ping 端点 | 0.3 周 |
| V0.2 | F10：README 翻译触发（若 §12(详见 `docs/6-发版与上架/v1-上架信息准备.md`) Q2 在 V0.1 未做） | 复用 `ReadmeTranslationService` | 0.3 周 |
| **V0.3** | F11：跨站采集（HN / Reddit / 技术博客 → Activity Discovery 源） | 等 R-04 主表 + Discovery 流水线稳定 | 2 周 |
| V0.3 | F12：Repo 对比候选（浏览器收集 → App 对比页） | 依赖 P2 AI 高级"对比报告"功能落地 | 配套 |
| V0.3 | F13：Firefox / Safari 扩展（如有 ≥10% 用户需求） | Safari 需 Xcode 项目化 | 评估后决定 |
| **评估** | F14：Research Session（调研主题 / 来源 / 决策） | 隐私敏感 + 模型成本 | 先观测 V0.1 / V0.2 用户行为 |

---

## 9. 数据流与架构图

### 9.1 V0.1 系统组成

```
┌─────────────────────────────────────────────────────────┐
│                  Chrome 浏览器                           │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Starcat Companion 插件 (MV3)                     │   │
│  │  ├── content script  (注入 GitHub 页面 → F1/F4)  │   │
│  │  ├── service worker  (deep link 触发 / 状态查询) │   │
│  │  ├── popup           (toolbar 点击入口)          │   │
│  │  ├── context menu    (右键菜单 → F3)             │   │
│  │  └── chrome.storage  (Companion Token / 偏好)    │   │
│  └──────────┬─────────────────────────┬─────────────┘   │
│             │                         │                 │
│       fetch │                         │ window.open    │
│             ▼                         ▼                 │
└─────────────┼─────────────────────────┼─────────────────┘
              │                         │
              │ http://127.0.0.1:5051   │ starcat://...
              │ (Bearer Auth)           │ (URL Scheme)
              │                         │
              ▼                         ▼
┌─────────────────────────────────────────────────────────┐
│                 Starcat macOS App                        │
│  ┌──────────────────────────────────────────────────┐   │
│  │  本地 HTTP 服务（新增模块）                         │   │
│  │  ├── /local/v1/ping                              │   │
│  │  └── /local/v1/state                             │   │
│  └────────┬─────────────────────────────────────────┘   │
│           │                                             │
│           ▼                                             │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Deep Link Router（已有，扩展 5 个 action）         │   │
│  └────────┬─────────────────────────────────────────┘   │
│           │                                             │
│           ▼                                             │
│  ┌──────────────────────────────────────────────────┐   │
│  │  既有架构（零改动）：                                │   │
│  │  ├── StarredRegistry / RepoTagRepository         │   │
│  │  ├── RepoNoteRepository / AISummaryRepository    │   │
│  │  ├── RepoRepository (R-04 主表 github_repos)     │   │
│  │  └── RepoAIInsightService / ReadmeTranslation    │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 9.2 关键数据通路

| 用户动作 | 数据通路 |
|---|---|
| 浏览 GitHub repo（F1） | content script 提取 owner/repo → fetch `/local/v1/state` → 渲染胶囊 |
| 切换浏览器 tab（F1 / F5） | service worker 监听 `chrome.tabs.onActivated` → fetch `/local/v1/state` → 更新角标 + 通知 content script |
| 点击采集（F2 / F4） | service worker 触发 `chrome.tabs.create({url: 'starcat://capture?...'})` → macOS 路由 → App 入主表 + 跳详情页 |
| 右键追加笔记（F3） | service worker 收到 contextMenus.onClicked → 触发 `starcat://capture-note?...` |
| 复制 deep link（F4） | service worker 写 `navigator.clipboard.writeText('starcat://repo?...')` |

### 9.3 与 R-04 主表的对接

R-04 主表 `github_repos` 的 `source_types` 字段：

```json
{
  "gh_repo_id": 123456,
  "owner": "vercel",
  "name": "swr",
  "source_types": ["weekly", "zread", "clip"],
  "first_seen_at": "...",
  "last_seen_at": "..."
}
```

浏览器采集（F2）的本质是给 `source_types` 数组追加 `"clip"`：

- 与 weekly / zread / discovery 三个数据源**完全对等**
- Activity 聚合页可以新增 `clip` 子分类（V0.2 评估），或保持当前 8 分类不变（用户能在 Manage 全列表看到，无需新分类）
- 详情页 full_name 同行来源标识（22 文档设计）可扩展展示 `clip` 来源摘要

> **结论**：R-04 落地后，浏览器采集是**零成本**的第 4 个数据源。

---

## 10. 收益与效率提升

### 10.1 用户视角（量化）

| 场景 | 之前耗时 | 之后耗时 | 提升 |
|---|---:|---:|---|
| 浏览到一个新项目 → 记录到 Starcat | 切 App + 搜索 + 输入笔记 ≈ 30~60s | 浏览器右键采集 ≈ 1~3s | **15~30×** |
| 看一个 repo 时回忆"我之前怎么评估的" | Cmd+Tab + 找 repo + 看 notes ≈ 10s | 胶囊直接显示首行 ≈ 0s | **∞** |
| 长 PR / Issue 阅读 | 手动看完 + 回头总结 ≈ 5~10min | 一键 AI 总结 ≈ 30s 等通知 | **10~20×** |
| Release 升级评估 | 手读 changelog + 评估 ≈ 5min | 一键 AI 解释升级风险 ≈ 30s | **~10×** |
| 看 trending 决定是否 star | 切 App 看是否已收 ≈ 5s × N 项 | 行内 ✓ 标记 ≈ 0s × N 项 | **5~50×** |

### 10.2 产品视角

| 维度 | 收益 |
|---|---|
| **拉新** | Chrome Web Store 流量 ≫ Mac App Store；插件是天然的 Starcat 引流入口（"为何要装 macOS App？因为 Companion 的能力在 App 里"）|
| **黏性** | 用户每天看 GitHub 即感受 Starcat 价值，不必"想起来用"——这是把"打开 App"的入口从 Dock 扩展到了"任何 GitHub 页面" |
| **数据飞轮** | 用户主动 push 的 repo 是高质量信号，可反哺 R-04 主表的 source 多样性（`clip` 与 weekly / zread / discovery / trending 并列）；后续可分析"哪些 clip 后来被 star 了"等行为指标 |
| **差异化** | 同类工具（Stars Manager / Star Track / GitHub 官方 List）**没有任何一个**做"私人元数据浏览器投射"——这是 dong4j 多年打磨的「整理 / 理解 / 找回 / 评估」核心价值在浏览器侧的天然延伸 |
| **架构复用** | F1 + F5 共享 `/local/v1/state`；F2 / F3 / F4 共享 deep link 5 actions；零新增 GRDB 表；零新增视图 |

### 10.3 与 Starcat 已有功能的协同放大

| Starcat 功能 | 插件如何放大其价值 |
|---|---|
| 标签 / 笔记 / 阅读状态 | 浏览器侧立即可见（F1 胶囊），让"私人元数据"价值不再被 App 边界锁住 |
| AI 摘要 / 翻译 / 标签推荐 | 触发入口从 App 内延伸到所有 GitHub 长文页面（V0.2 F6/F7/F10）|
| Release 订阅 + 通知 | 浏览器图标角标 + 胶囊状态点（F1/F5），让"哪些项目我在追"实时可见 |
| Trending / Weekly / Discovery | 浏览器看 trending 时直接显示 ✓ 标记 + 私人评分（V0.2 F8）|
| R-04 聚合表 `github_repos` | `source=clip` 作为新 source 自然嵌入，不动主表结构（V0.1 F2）|
| StarredRegistry @Observable | `/local/v1/state` 直接消费 registry，秒级一致 |
| Activity 聚合页 8 分类 | 浏览器采集自然落入 Activity 视图，无需新分类（也可 V0.2 评估单独的 `clip` 子分类）|

---

## 11. 风险与缓解

| ID | 风险 | 缓解方式 |
|---|---|---|
| R1 | 本地 HTTP 端口 5051 被其他应用占用 | App 启动时探测 5051~5060 范围内可用端口，写入 `companion.token` 一并持久化端口号；插件设置页支持手动配置端口 |
| R2 | Chrome 插件 fetch `http://127.0.0.1` 受 mixed content / CORS 限制 | App 端 HTTP 响应明确写 `Access-Control-Allow-Origin: chrome-extension://<id>`；MV3 manifest 申请 `host_permissions: ["http://127.0.0.1:*/"]` |
| R3 | GitHub 改版破坏浮按钮 / 胶囊注入位置 | 注入位置选**最稳定的 DOM**（README 上方而非 About 区）；用 `MutationObserver` 容错；版本不匹配时降级为 toolbar popup（不影响核心采集功能）|
| R4 | Companion Bearer Token 泄漏（用户截图 / 误传 / 同事看到） | Token 仅本地有效（127.0.0.1 不外传）；App 设置页提供"重置 Companion Token"入口；Token 不应是 GitHub Token 同源（独立生成，泄漏后只能调本地服务，无远程影响）|
| R5 | 插件 + App 版本不匹配 | `/local/v1/ping` 返回 `schema_version`；插件检查不兼容时浮提示"请升级 Starcat App / 插件"；deep link 携带 `version` 参数让 App 端兼容判定 |
| R6 | 用户开多个浏览器（Chrome / Edge / Arc） | 端口共享即可；Token 一份用所有浏览器都能用；插件首次安装引导文案明确告知"Token 跨浏览器复用" |
| R7 | Starcat App 关闭时用户点 capture | deep link 会唤起 App（macOS 系统级注册的 URL Scheme 自动唤起）；`/local/v1/state` 失败则不显示胶囊（已设计降级，§5.3）|
| R8 | 用户隐私顾虑（"插件读了我所有 GitHub 浏览历史？"）| ① 插件**只在用户主动触发**时读取当前 tab URL；② 不申请 `tabs` / `history` / `webRequest` 等敏感权限（§6.4）；③ 状态查询的 fullname 仅在内存缓存 60s，不上传不持久化；④ 公开 README 与隐私政策清晰说明 |
| R9 | Chrome Web Store 审核驳回（权限申请过宽）| 严格遵守 §6.4 最小权限；首发版不申请任何 `<all_urls>`、不夹带任何分析 / 统计 SDK；隐私政策与权限说明对齐 |
| R10 | 用户已安装 N 个 Star 管理插件互相冲突注入 | F4 浮按钮位置可拖拽；可一键完全隐藏；F1 胶囊位置选择保守（README 上方独占行，不与其他插件常见的 sidebar / 顶 bar 注入位置冲突）|

---

## 12. 待 dong4j 拍板的未决项

| 编号 | 问题 | 我的倾向 | 理由 |
|---|---|---|---|
| Q1 | 插件命名 | **Starcat Companion** | 与原方案一致，能传达"配套"语义；中性、不抢 Starcat 主品牌 |
| Q2 | V0.1 是否包含 README 翻译触发？（即 F10 提前到 V0.1）| **包含** | README 翻译 App 已有（HOM-68），浏览器一键触发零工程成本，对中文用户价值高 |
| Q3 | 浏览器图标角标是否显示"未读 Release 计数"？| **显示** | 用户感知最强；技术成本只是 `/local/v1/state` 多返回一个数字字段 |
| Q4 | 私人胶囊在 GitHub 页面的注入位置 | **README 上方独占一行** | 比 About 区右上更稳定（README 是 GitHub 页面最稳定的容器之一，About 区结构变更概率更高）|
| Q5 | 是否支持 Firefox / Safari 扩展？| **MVP 仅 Chromium 系**（Chrome / Edge / Arc / Brave）| Safari 需 Xcode 项目化；Firefox MV3 兼容仍在演进；Chromium 系覆盖 ≥85% 开发者用户 |
| Q6 | 是否做"Starcat 未启动时自动唤起"？| **deep link 默认行为即可** | macOS 自动唤起注册了 scheme 的 App，不额外做唤起逻辑；F1 / F5 走本地 HTTP 时端口不通 → 自动降级 |
| Q7 | 插件设置页要不要支持"切换连接的 Starcat 实例"（多设备）| **MVP 不做** | 单实例对接，token 配置一次即可；多实例 V0.3 评估（用户用得着才做）|
| Q8 | 插件名空间和 Starcat App URL Scheme 是否复用同一 scheme `starcat://`？| **复用** | 已规划的 deep link 路径就是 `starcat://`，插件直接用；不需要为插件单独定义 scheme |
| Q9 | F2 采集是否要弹"采集成功"toast 反馈？还是直接跳详情页？| **直接跳详情页** | 跳详情页本身就是反馈；少一层 toast 减少视觉打扰 |
| Q10 | 是否在 Activity 聚合页新增 `clip` 子分类？还是混在 Manage 全列表里看？| **V0.1 不新增**，V0.2 评估 | V0.1 先验证用户是否真的高频用 F2 采集；如果数据显示 clip 累计 ≥50 条且单独检索需求强，再新增 |

---

## 13. 实施里程碑（粗粒度）

> **粗估 V0.1 总工期 3 周**（不含 Chrome Web Store 审核等外部时间）。

| 里程碑 | 内容 | 工期 | 依赖 |
|---|---|---|---|
| M1 | Starcat App 内嵌本地 HTTP 服务模块 + 2 个端点 + Companion Token 持久化 + 设置页 Companion 分组 | 3~4 天 | 无（独立可做） |
| M2 | Starcat App 扩展 deep link 路由（5 个 action）+ R-04 主表 `source=clip` 写入路径 | 2~3 天 | 若 R-04 后端未上线，临时用现有 `repos` 表替代，未来零迁移成本切换 |
| M3 | Chrome 插件项目脚手架（MV3 + content script + service worker + popup + manifest）| 2 天 | 无 |
| M4 | 插件 F1 状态镜像胶囊（content script 注入 + fetch 本地 HTTP）| 3~4 天 | M1 完成 |
| M5 | 插件 F2 / F3 / F4（deep link 触发 + 浮按钮 + 右键菜单）| 2~3 天 | M2 完成 |
| M6 | 插件 F5 浏览器图标角标 + service worker tab 切换监听 | 1~2 天 | M1 完成 |
| M7 | 联调 + 文档（README + 隐私政策 + Chrome Web Store 商店描述 + 用户引导）| 2~3 天 | M1~M6 完成 |
| M8 | Chrome Web Store 提交审核 | 1 周（外部） | M7 完成 |

> M1 / M3 可并行启动。M4 / M5 / M6 在 M1 / M2 / M3 全部完成后并行。

---

## 14. 文档关联与同步

### 14.1 落地时需同步更新的文档

| 文档 | 更新内容 |
|---|---|
| `docs/功能实现总览.md` | ① 在 §5（P2）或新增 §5.6 加 Chrome 插件计划条目；② §10 变更日志加方案落档行；③ 实施完成后按 CLAUDE.md / AGENTS.md 工作流要求标记 + 写实现说明 |
| `docs/3-设计/详细设计/16-活动页设计.md` | V0.2 若决定新增 `clip` 子分类，在 §3 Activity 分类章节追加；V0.1 不动 |
| `docs/3-设计/详细设计/21-weekly-api-后端3源聚合改造.md`（R-04） | 在 §2.4 source_types 列表的描述里增加 `clip`，与 weekly/zread/discovery 并列 |
| `docs/3-设计/详细设计/22-weekly-客户端3源聚合对接.md` | 来源标识的 source 类型列表增加 `clip` 渲染样式 |
| `docs/7-工具与脚本/Swift-学习索引.md` | 实施 M1 时若引入 SwiftNIO / Network.framework 嵌入式 HTTP server，关键概念加索引 |
| 新增 `docs/3-设计/详细设计/24-本地HTTP服务设计.md`（如有必要）| M1 详细设计若复杂度高（端口探测 / Token 持久化 / Bearer 中间件 / CORS），可单独拆出；MVP 简单则不拆 |

### 14.2 不需要修改的文档

- `docs/3-设计/详细设计/01-数据库设计.md` — 零新增表
- `docs/3-设计/详细设计/04-技术选型.md` — 浏览器侧技术栈是 Chrome MV3 + 原生 JS / TS，与 Starcat 主项目正交
- `docs/3-设计/详细设计/06-核心模块设计.md` — 不动 OAuth / Sync / Repository 边界
- 4 个后端 Go 服务 README / CHANGELOG — 不动后端

### 14.3 与 CLAUDE.md / AGENTS.md 工作流的关系

按现有约定：

1. 本文档落档完成 → 在 `功能实现总览.md` §5（P2）或新增 §5.6 加 `- [ ] Starcat Companion Chrome 插件方案落档` 已勾选条目
2. dong4j 拍板施工后 → 实施过程中按 §13(详见 `docs/3-设计/详细设计/23-Chrome-插件方案.md`) 里程碑勾选子项
3. 每个里程碑完成后 → 在 `功能实现总览.md` 对应条目下追加 `> 实现：...` 行
4. 第三方依赖（如 SwiftNIO）若引入 → 必须按 CLAUDE.md「开源致谢同步规则」追加 `AboutDependency` 条目

---

> **方案就绪状态**：本文档已覆盖背景、定位、能力边界、通信通道、MVP 范围、路线图、收益、风险、未决项、里程碑、文档关联十一个维度，足以作为 dong4j 拍板施工的依据。**待拍板事项见 §12(详见 `docs/6-发版与上架/v1-上架信息准备.md`) Q1~Q10**，建议优先就以下两项给方向：
>
> 1. **§6.2 反向链路是否走方案 A（本地 HTTP + Bearer）** —— 这是 M1 / M4 / M5 / M6 的地基
> 2. **§12(详见 `docs/6-发版与上架/v1-上架信息准备.md`) Q1 / Q2 / Q4 / Q5** —— 决定 MVP 范围与外观，影响 M3 / M4 工期估算
