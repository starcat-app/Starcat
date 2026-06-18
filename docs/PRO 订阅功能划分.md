# PRO 订阅功能划分（v1 草案）

> 用途：梳理 Starcat 应用所有功能（已实现 + 规划中），按「免费版 vs Pro 版」给出明确划分建议，作为后续 StoreKit 2 接入、付费墙 UI 设计、Quota 系统的设计基线。
>
> 状态：**§8 核心项已拍板（2026-06-18）**；实施规格以 **`docs/StoreKit订阅上架方案.md`** 为单一信任源。
>
> 前置阅读：`docs/StoreKit订阅上架方案.md`（拍板结果 + 技术方案）、`docs/功能清单.md` §7、`docs/需求分析.md` §7。

---

## 1. 背景与目的

### 1.1 问题陈述

当前 Starcat 处于「全功能开发期」——所有功能（含 AI、Release 订阅、向量搜索、自动整理调度器、AI 对话浮动窗口、AnySearch 网络上下文等高成本特性）都对所有用户开放。

随着接入 StoreKit 2（`docs/工程进度/功能实现总览.md` §5.3，标记 P2）的时点临近，需要提前明确**哪些能力是免费版的「基础工具价值」，哪些进入 PRO 订阅的「增值能力」**。否则会出现以下风险：

- AI 代理后端（自建/BYOK 代理）持续承担推理 + 网络成本，但所有用户无差别消费；
- 已经实现但未做付费门控的功能（如 AI 浮动窗口、自动整理）后续要"加锁"，会让早期用户体感倒退；
- App Store 上架时的 Pro 订阅卖点缺乏完整说明，付费墙 UI 无设计依据。

### 1.2 既有定价框架

`docs/需求分析.md` §7 和 `docs/功能清单.md` §7 已经给出了初步定价方案：

```
免费版（$0）：基础管理（同步、标签、搜索、笔记）
Pro 订阅（$29.99/年 或 $79.99 买断）：AI 功能 + Release 订阅通知 + 云端同步
自建服务模式：需要 Pro 订阅 / 用户自行提供 API Key
```

但这份框架是 **2026 年 5 月**的版本，**没有覆盖最近 6 个月新落地的 30+ 项功能**，包括：

- AI 浮动窗口 + 多轮对话 + 对话历史磁盘持久化（HOM-150、HOM-70）
- AnySearch 全局搜索中心 ⌘K（Local + GitHub + Web）+ 磁盘缓存（HOM-69）
- AI 自动整理调度器（HOM-126）
- AI 代码上下文 / RepoContextPacker（HOM-150 子项）
- 向量索引（含三阶段降级、行级 diff、慢速预拉）
- README 翻译（HOM-68）
- Activity 聚合页、Trending 三源聚合、Discovery、Wiki API 对接
- Starred 列表 HTML/Markdown 导出 + 用户分享卡片
- 浏览器伴侣（Chrome 插件方案 v1.0 已落档）
- CodeFlow 集成

本文档基于 `docs/工程进度/功能实现总览.md` 的最新清单做精细化重梳理。

---

## 2. 划分原则（决策框架）

按以下 5 条优先级从高到低判断每个功能的归属：

### 原则 ① 基础工具价值 → 免费

「管理 GitHub Stars」本身的核心工作流（同步 + 浏览 + 整理 + 搜索 + 阅读 README）必须在免费版下能**完整闭环**。

理由：没人会为"只是能列出 Stars"付费——这是 GitHub 网页就能做的。Starcat 在免费版的卖点是**原生 macOS 体验 + 本地优先 + 离线浏览 + 精致 UI**。

### 原则 ② 持续算力消耗 → Pro

任何**需要持续调用外部 AI Provider** 的功能（无论是 BYOK 还是自建代理）算 Pro 范畴。

理由：① AI API 成本不可忽略（即使 BYOK 也需要服务端做协调）；② 后台自动跑的能力（如自动整理调度器）天然属于"长期价值"，让付费用户独享更合理；③ 与"基础工具"明显划界，付费墙的边界清晰。

### 原则 ③ 自建后端服务 → 默认 Pro，但有例外

依赖 Starcat 后端服务（`starcat-trending-api` / `starcat-weekly-api` / `starcat-wiki-api` / `starcat-sharing-api` 等）的功能默认归 Pro，因为这些服务承担**长期服务器 + 数据抓取 + AI 增强**成本。

**例外**：仅做"基础数据浏览"且**不消耗 AI**的端点可以让免费用户访问（比如 Trending 列表本身浏览免费、Trending 的 AI 摘要 Pro），用作"发现 → 加入 Stars"的引流入口。

### 原则 ④ 一次性产物 / 工具型增值 → 免费

「导出 HTML / 分享卡片 / JSON 导入导出 / 个人主页贡献草坪」等**一次性产物**，不持续消耗资源，是「基础工具」的延伸，归免费。

### 原则 ⑤ 数量限制作为分级杠杆，而非锁死功能

避免"功能 A 完全锁死给 Pro"的硬墙策略。对于免费 + Pro 都可访问的功能，用「数量上限」作为分级杠杆（如标签 ≤ 20 个、订阅 Release ≤ 5 个仓库、AI 调用赠送 3 次试用）。

理由：让免费用户也能"体验"AI / Release 订阅，再用配额杠杆推升级。Bear / Things 都用这套，转化率比硬墙高。

---

## 3. 完整功能盘点（截至 2026-06-15）

> 基线来源：`docs/工程进度/功能实现总览.md` 进度仪表盘（P0 60/60 = 100%；P1 42/29 = 69%；P2 31/2 = 6%；总计 133 项 / 已完成 85 项 = 64%）。
>
> 本节仅列功能名称索引；详细实现说明请回看「总览」对应章节。

### 3.1 已实现（85 项）

**P0 完整 60 项 → 见「总览」§3**：

- 账号与同步（11 项）：OAuth Device Flow、AuthSession 状态机、集中式 401 处理、Stars 全量/增量同步、Rate Limit 解析 + 主动退避、ETag 缓存、同步状态展示、Token 加密存储（D-16）、登录页 V2、Web Application Flow OAuth（未实现）
- 主界面（17 项）：三栏布局、All Repos / Untagged / Languages 视图、列表密度、Sidebar 用户卡、贪吃蛇多玩法、用户 profile 离线缓存（HOM-175）、Starred 列表 HTML/MD 导出（HOM-174）、用户分享卡片（HOM-173）、Sidebar 个人主页 + 贡献草坪（HOM-PROFILE）、Cmd+, 设置面板、主窗口尺寸恢复、Tags 视图、排序功能（8 种）、主页按钮三栏拆分、Sidebar 折叠 header 修复、[HOM-46] 切换分类优化、登录后默认进 Manage
- Repo 详情（10 项）：元数据卡片、详情页信息区高度优化、滚动隐藏信息面板、README WebView 渲染、README 抓取缓存（ETag）、softTtl / 404 session 缓存、SWR + API 拆分、HTTPS/SSH Clone URL 复制、外链快捷入口、取消 Star
- 整理功能（6 项）：标签 CRUD、颜色/图标、给 repo 打标签、批量添加标签、私有笔记、状态管理
- 搜索与过滤（7 项）：FTS5 全文搜索、全局搜索框 + 显式提交、FTS 查询安全化、FTS5 召回扩展 + BM25 + notes_fts trigram、按语言/标签/状态/Archived/Fork 过滤
- 数据管理（3 项）：本地 SQLite、Migration v1、缓存清理
- 关于窗口（1 项）：Cmd+I + Credits
- 设置项偏好（2 项）：主题切换、关闭应用内动画

**P1 已完成 29 项 → 见「总览」§4**：

- Release 订阅追踪（8/9）：API 拉取、订阅/取消、后台轮询、Release 通知、时间线、已读/未读、智能资产过滤、一键复制下载链接（剩"直接下载"待实现）
- AI 摘要与分析（10 项）：AI 服务配置（多 Provider BYOK）、Key 本地存储、单仓 AI 摘要、AI 标签推荐、AI 确认流程、AI 结果本地缓存、AI 浮动窗口 + 多轮对话（HOM-150）、自动后台 AI 整理（HOM-126）、README 翻译（HOM-68）、AnySearch 磁盘缓存（HOM-69）、AI 对话历史磁盘持久化（HOM-70）、RepoContextPacker
- AI 语义搜索（6 项）：Embedding 服务端计算、向量本地存储、三段式增强、向量搜索改进（含 indexedText 三级降级 + 行级 diff）、Summary/Tags/Chat prompt 模块化、Embedding 任务 prompt 占位符化
- AI 每日推荐 / Trending（7 项）：GitHub Trending 抓取、日/周/月榜筛选、Trending AI 摘要、个性化推荐、一键订阅、AI 评分算法、Trending GRDB 持久化、Activity 聚合页
- 搜索增强：全局搜索中心 ⌘K（Local + GitHub + AnySearch Web）
- AI Discovery（Show HN 抓取，后端完成 5/9，客户端 0/4）
- 后端 API 扩展（zread 多源化、trending-api 单源化、weekly-api 3 源聚合、wiki-api 客户端对接、languages 聚合）

**P2 已完成 2 项 → 见「总览」§5**：

- CodeFlow 集成（GitHub ZIP 下载 + JSZip 解压 + 浏览器展示）
- 浏览器伴侣方案 v1.0 落档（实施未开始）

### 3.2 规划中（48 项）

- P0 未做：Web Application Flow OAuth、Liquid Glass 适配、JSON 导入/导出、详情页信息增强（Website / Open Issues / Open PR / 最新 Release）、独立 README 窗口、Pin 置顶窗口、结构化搜索页
- P1 未做：直接下载 Release 资产、AI 同义标签检测、14 预设分类、支持平台识别、批量未分类整理（队列化）、自然语言查询、命中原因说明、保存搜索、AI Discovery 客户端 4 项
- P2 未做：CloudKit 同步全套、iPhone / iPad / watchOS 适配、菜单栏入口 / 全局快捷键 / Spotlight / Shortcuts / Widget、StoreKit 2 + Pro 订阅 + Quota + 恢复购买、AI 高级（健康度 / 周报 / 调研报告 / 对比报告 / Awesome List 导出）、效率功能（独立窗口 / Pin / 最近查看 / 常用标签）、浏览器伴侣 V0.1/V0.2/V0.3

---

## 4. 免费版功能详单

> 原则①、④ 适用。免费用户能完整完成"管理我的 GitHub Stars"工作流。

### 4.1 账号与同步（全免费）

| 功能 | 状态 | 备注 |
|---|---|---|
| GitHub OAuth Device Flow 登录 | ✅ | 包括 401 自动失效处理 |
| Stars 全量同步 | ✅ | 1801 真实 stars 验证 |
| Stars 增量同步（starred_at cutoff） | ✅ | |
| Rate Limit 主动退避 + 倒计时 UI | ✅ | |
| ETag 缓存（首页 304 命中早退） | ✅ | |
| Token 加密本地存储（AES-GCM） | ✅ | |
| Web Application Flow OAuth | ⏳ | 替换 Device Flow（依赖后端） |

### 4.2 主界面与三栏布局（全免费）

| 功能 | 状态 |
|---|---|
| Liquid Glass NavigationSplitView 三栏 | ✅ |
| Sidebar（All Repos / Untagged / Tags / Languages） | ✅ |
| 列表密度（Compact / Card） | ✅ |
| 排序（8 种，按名称 / Star 数 / 更新时间） | ✅ |
| 按 Archived / Fork / 状态 / 语言 / 标签过滤 | ✅ |
| 主页操作按钮三栏拆分 + Finder 式搜索框 | ✅ |
| Sidebar 折叠 / 用户卡 / 个人主页贡献草坪 + 贪吃蛇 6 种玩法 | ✅ |
| 用户 profile 离线缓存 + 后台刷新 + 反向 push（HOM-175） | ✅ |
| 主题切换 + 关闭应用内动画 | ✅ |
| 主窗口尺寸恢复 | ✅ |
| 登录后默认进 Manage + 恢复上次分类 | ✅ |

### 4.3 Repo 详情（全免费，AI 部分除外）

| 功能 | 状态 |
|---|---|
| 元数据展示卡片（名称 / 描述 / 语言 / Star / Fork） | ✅ |
| README WebView 渲染（GitHub HTML） | ✅ |
| README 抓取 + ETag 缓存 + SWR + softTtl | ✅ |
| HTTPS / SSH Clone URL 复制 | ✅ |
| GitHub 页面快捷入口（Issues / Pulls / Releases / Homepage） | ✅ |
| 取消 Star 操作 | ✅ |
| 滚动隐藏信息面板 | ✅ |
| 详情页信息增强（Website / Open Issues / 最新 Release，零额外成本部分） | ⏳ |

### 4.4 整理与笔记（全免费）

| 功能 | 状态 | 数量上限建议 |
|---|---|---|
| 标签 CRUD（含合并） | ✅ | 见 §6 |
| 标签颜色 / 图标（12 预设色 + 30 SF Symbol） | ✅ | — |
| 给 repo 打标签 / 解除 | ✅ | — |
| 批量添加标签 + 浮动操作栏 | ✅ | — |
| 私有笔记（防抖 800ms 自动保存） | ✅ | — |
| 状态管理（未读 / 在读 / 在用 / 废弃） | ✅ | — |

### 4.5 搜索与过滤（全免费）

| 功能 | 状态 |
|---|---|
| FTS5 全文搜索（name / owner / description / notes） | ✅ |
| FTS5 召回扩展 + BM25 排序 + notes_fts trigram 中缀 | ✅ |
| 按语言 / 标签 / 状态 / Archived / Fork 过滤 | ✅ |
| 全局搜索中心 ⌘K（Local + GitHub） | ✅ |
| 结构化搜索页 | ⏳ |
| 保存搜索 | ⏳ |

> ⚠️ **AnySearch Web 检索结果**：见 §5.3，归 Pro。免费版的 ⌘K 仅 Local + GitHub 两个数据源，不接入 AnySearch。

### 4.6 数据管理（全免费）

| 功能 | 状态 |
|---|---|
| 本地 SQLite + GRDB 缓存 | ✅ |
| 缓存清理（README + 图片 + 日志 + AnySearch + 对话历史） | ✅ |
| JSON 导入 / 导出（OhMyStar / Astral 兼容） | ⏳ |

### 4.7 一次性产物与导出（全免费，原则 ④）

| 功能 | 状态 |
|---|---|
| Starred 列表 HTML 导出（含 AI 摘要按钮 + Tag 筛选） | ✅ |
| Starred 列表 Markdown 导出 | ✅ |
| 用户分享卡片（5 套主题：杂志 3 + ID 卡 2） | ✅ |
| 分享卡保存为图片 / 分享到 X | ✅ |
| Sidebar 个人主页（bio + 5 图标行 + 贡献草坪 + 贪吃蛇） | ✅ |

> ⚠️ **HTML 导出中的「AI 摘要」按钮**：导出动作免费，但导出内容里嵌入的 AI 摘要是用户**已经生成过**的（来自 ai_summaries 表）；若用户从未生成过 AI 摘要，导出 HTML 中相关卡片不显示 AI 摘要按钮。换句话说，**生成**摘要是 Pro，**导出已有数据**是免费——零矛盾。

### 4.8 设置与关于（全免费）

| 功能 | 状态 |
|---|---|
| Cmd+, 设置面板 | ✅ |
| 主题切换（system / light / dark） | ✅ |
| 关闭应用内动画（无障碍） | ✅ |
| 关于窗口（Cmd+I）+ Credits 第三方致谢 | ✅ |

---

## 5. PRO 版功能详单

> 原则②、③ 适用。所有需要持续 AI 算力 / 自建后端服务 / 长期后台调度的能力。

### 5.1 AI 摘要与分析（核心 Pro）

| 功能 | 状态 | 理由 |
|---|---|---|
| AI 服务配置（多 Provider BYOK：OpenAI / DeepSeek / OpenRouter / Ollama / LM Studio + 18 个新增） | ✅ | 配置 UI 本身免费可见（让用户预览能力），但**激活使用**需要 Pro |
| AI API Key 本地存储（AES-GCM 加密） | ✅ | 同上 |
| 单仓 AI 摘要（结构化中文摘要 + Markdown 渲染） | ✅ | 持续 AI 调用 |
| AI 标签推荐 + 置信度 + 确认流程 | ✅ | 持续 AI 调用 |
| AI 结果本地缓存（ai_summaries 表 + source_hash） | ✅ | 缓存本身免费，**生成动作**Pro |
| AI 浮动窗口 + 多轮对话（HOM-150） | ✅ | 持续 AI 调用 + 高级体验 |
| AI 对话历史磁盘持久化 + 多 session 管理（HOM-70） | ✅ | 同上 |
| 自动后台 AI 整理（HOM-126）—— 启动/同步/24h 三类触发 | ✅ | 后台持续算力消耗 = Pro 强属性 |
| README 翻译（HOM-68） | ✅ | 翻译走 AI 服务 |
| 同义标签检测 | ⏳ | 持续 AI 调用 |
| 14 预设分类 + 支持平台识别 | ⏳ | 持续 AI 调用 |
| 批量未分类整理（队列化） | ⏳ | 持续 AI 调用 |

### 5.2 AI 语义搜索（核心 Pro）

| 功能 | 状态 |
|---|---|
| Embedding 服务端计算（BYOK） | ✅ |
| 向量本地存储（SQLite BLOB） | ✅ |
| 三段式增强（重标定 + 字面 boost + FTS hit 加权） | ✅ |
| 向量搜索改进（三级降级 indexedText + 行级 diff + 慢速预拉） | ✅ |
| Summary / Tags / Chat prompt 模块化重构 + 占位符归一化 | ✅ |
| Embedding 任务 prompt 占位符化 | ✅ |
| 自然语言查询（意图搜索） | ⏳ |
| 命中原因说明（LLM 解释为什么返回这些结果） | ⏳ |

### 5.3 AnySearch 网络上下文（Pro，原则②）

| 功能 | 状态 | 理由 |
|---|---|---|
| AnySearch Web 检索（接入全局 ⌘K 第三数据源） | ✅ | 第三方 Web Search API 持续消耗配额 + Token |
| AnySearch 作为 AI 摘要 / Chat 的外部上下文（24h 缓存） | ✅ | 同上 |
| AnySearch 磁盘缓存（30MB LRU + 全局搜索 6h / AI 上下文 24h） | ✅ | 缓存免费，**首次拉取**Pro |
| AnySearch 降级 banner | ✅ | 同上 |

### 5.4 AI 代码上下文 / RepoContextPacker（Pro）

| 功能 | 状态 |
|---|---|
| RepoContextPacker（CodeFlow ZIP → LLM 友好 XML 上下文） | ✅ |
| AI 摘要 / 对话注入代码上下文（让 LLM 从"看 README"升级为"读源码") | ✅ |
| 上下文产物管理（输出目录 / 占用统计 / 单项删除） | ✅ |
| Token 预算 4000-32000 / Tier 1 关键文件行数配置 | ✅ |

### 5.5 Release 订阅追踪（差异化 Pro）

| 功能 | 状态 | 备注 |
|---|---|---|
| Release API 拉取 + ETag | ✅ | |
| Release 订阅 / 取消订阅 | ✅ | **数量限制**：免费 ≤ 5 个仓库，Pro 无限 |
| 后台轮询调度器（NSBackgroundActivityScheduler） | ✅ | Pro：长期后台耗电 + 网络 |
| 新 Release 通知（UNUserNotificationCenter） | ✅ | 同上 |
| Release 时间线视图 + 已读/未读 | ✅ | |
| 智能资产过滤 + 一键复制下载链接 | ✅ | |
| 直接下载资产 | ✅ | NSSavePanel + URLSession.download；browser / API 双路径 fallback |

### 5.6 Trending / Discovery / Activity（混合：基础浏览免费 + AI 增强 Pro，原则③ 例外）

| 功能 | 状态 | 划分 |
|---|---|---|
| GitHub Trending 抓取 + 日/周/月榜 | ✅ | **免费**（基础发现入口） |
| Trending 一键订阅到 Stars | ✅ | **免费** |
| Trending GRDB 持久化（独立 trending_repos / trending_readmes 表） | ✅ | **免费** |
| Trending AI 摘要 | ✅ | **Pro**（AI 调用） |
| Trending AI 评分算法（多维度） | ✅ | **Pro** |
| 个性化推荐（基于用户收藏偏好） | ✅ | **Pro**（推荐计算 + AI） |
| Activity 聚合页（左侧活动 root + 中栏卡片 + 右栏详情） | ✅ | **免费**（信息流） |
| Activity 发行版按 repo 聚合 + Markdown release notes | ✅ | **免费**（Release 浏览） |
| Weekly 客户端 3 源聚合（ruanyf / ZRead / Hacker News） | ✅ | **免费**（外部资讯入口） |
| AI Discovery（Show HN 抓取 + LLM 分类） | ⏳ 后端完成 | **Pro**（LLM 分类） |
| Wiki API 客户端对接 | ✅ | **免费**（公开信息查询） |

### 5.7 CloudKit 多端同步（待决策，见 §8）

| 功能 | 状态 | 划分（候选） |
|---|---|---|
| CloudKit Schema 设计（tags / notes / status / saved_searches） | ⏳ | A:免费 / B:Pro |
| CloudKit 推送 + 拉取 + 合并 + tombstone | ⏳ | 同上 |
| 后台同步调度 | ⏳ | 同上 |
| 冲突解决 UI | ⏳ | 同上 |

### 5.8 浏览器伴侣 Chrome 插件（Pro）

| 功能 | 状态 | 理由 |
|---|---|---|
| Starcat App 本地 HTTP 服务 + deep link | ⏳ | 高级集成体验 |
| V0.1 MVP（5 项功能：登录态同步 / 一键 Star / 跳转 App 详情 / 标记已读 / Trending 同步） | ⏳ | Pro |
| V0.2 增强（Issue / PR / Release Notes 一键 AI 总结） | ⏳ | Pro（AI 调用） |
| V0.3 跨站采集（HN / Reddit / 技术博客 → Discovery） | ⏳ | Pro（依赖后端） |

### 5.9 AI 高级功能（远期 Pro）

| 功能 | 状态 |
|---|---|
| 项目健康度评分（commit / release / issue / archived 多维度） | ⏳ |
| AI 周报（月度技术圈总结） | ⏳ |
| 调研报告生成（Markdown） | ⏳ |
| 对比报告（多项目横向） | ⏳ |
| Awesome List 导出（格式化） | ⏳ |

### 5.10 Apple 生态深度集成（混合：基础免费 + AI 唤起 Pro）

| 功能 | 状态 | 划分 |
|---|---|---|
| 菜单栏入口（MenuBarExtra） | ⏳ | **免费** |
| 全局快捷键（唤起 ⌘K 搜索中心） | ⏳ | **免费** |
| Spotlight 搜索（App Intents） | ⏳ | **免费**（基础查找） |
| Shortcuts 支持（Siri Shortcuts） | ⏳ | **免费**（自动化基础） |
| Widget（桌面小组件） | ⏳ | **免费** |
| Shortcuts → "用 AI 总结这个 repo" 动作 | ⏳ | **Pro**（AI 调用） |
| Spotlight → "AI 智能找 repo" 命令 | ⏳ | **Pro**（语义搜索调用） |

---

## 6. 数量限制矩阵（分级杠杆，原则⑤）

> 为避免硬墙策略，对部分功能在免费版加数量上限，让用户能"体验"完整功能再触发付费需求。
>
> 所有数字均为**草案建议**，需要 dong4j 在 §8 确认。

| 维度 | 免费版上限 | Pro 版 | 备注 |
|---|---|---|---|
| **Stars 同步数量** | 无限制 | 无限制 | ✅ 同步是基础工具，不限 |
| **标签数量** | 20 个 | 无限制 | 类比 Bear / Things，足够轻度用户但激励重度用户升级 |
| **标签批量添加单次目标 repo 数** | 50 个 | 无限制 | |
| **私有笔记数量** | 无限制 | 无限制 | ✅ 用户已有数据不限 |
| **AI 单仓摘要次数** | **3 次试用**（一次性） | 无限制 / 配额 | 试用后引导升级；Pro 走配额（500/月）或 BYOK 无限 |
| **AI 标签推荐次数** | **3 次试用**（一次性） | 无限制 / 配额 | 同上 |
| **AI 对话（多轮 Chat）会话数** | 1 个 active session（不持久化） | 无限 + 磁盘持久化 + 多 session | |
| **README 翻译数量** | 5 次试用 | 无限制 / 配额 | |
| **AI 自动整理（HOM-126）** | 完全禁用（设置页可见但置灰） | 启用 + 三类触发 | 后台调度 Pro 强属性 |
| **AnySearch Web 检索调用** | 完全禁用（⌘K 仅 Local + GitHub） | 启用（Pro 配额或 BYOK） | |
| **AI 代码上下文 / RepoContextPacker** | 完全禁用 | 启用 | |
| **Release 订阅数量** | 5 个仓库 | 无限制 | |
| **AI Trending 摘要 / 评分** | 完全禁用（基础列表免费） | 启用 | |
| **个性化推荐** | 完全禁用 | 启用 | |
| **Trending 列表浏览** | 无限制 | 无限制 | ✅ |
| **Activity 聚合页** | 无限制 | 无限制 | ✅ |
| **多 AI Provider 配置数** | 1 个 | 无限制 | 免费版仅允许一个 BYOK Profile |
| **JSON 导出/导入** | 无限制 | 无限制 | ✅ 一次性产物 |
| **Starred HTML / Markdown 导出** | 无限制 | 无限制 | ✅ 一次性产物 |
| **CloudKit 同步设备数** | 待定（见 §8） | 待定 | |

### 6.1 试用配额返还策略

- **3 次试用**指首次安装后赠送，不再返还（避免被卸载重装薅羊毛）；
- 升级 Pro 后试用次数清零（不计入正式配额）；
- BYOK 模式下，**用户自己的 API Key 调用不消耗试用次数**——这是为了让"我用我的 Key 试试效果"的体验完全无阻力，同时引流到"配 Key 麻烦 → 干脆订阅算了"的升级路径。

---

## 7. 推荐试用 / 免费策略

### 7.1 14 天 Pro 全功能试用

参考 Things / Bear / Day One。新用户首次启动获得 14 天 Pro 试用，试用期内所有 Pro 功能解锁。

理由：AI 类功能需要用户**真的用一段时间**才能体感价值（一次试用 3 个标签推荐看不出 AI 比人工好在哪），14 天给足体验窗口。

### 7.2 早期采用者优惠

`docs/需求分析.md` §7 已建议：上架首年 $19.99/年（标价 $29.99/年）。建议同时引入：

- 早鸟买断 $49.99（标价 $79.99）—— 前 1000 个买断用户
- 首发期 1 个月：买断价等于 1.5 年订阅价格
- 学生 / 教育邮箱永久 50% 折扣（参考 Tower / JetBrains）

### 7.3 BYOK 用户也需要 Pro 资格的理由

虽然 BYOK 用户不消耗 Starcat 后端 AI 配额，但仍需 Pro 订阅，原因：

1. **AI 功能 UI / 集成成本**：AI 浮动窗口、对话历史、自动整理调度器、向量搜索、AnySearch 上下文等是 Starcat 的核心研发投入，不应免费送给"自带 Key"的用户；
2. **避免劝退普通用户**：如果 BYOK 免费，新用户会被引导去配 Key（门槛高），而不是直接订阅（路径短）；
3. **参考竞品**：Raycast Pro / Cursor / Cherry Studio 都是「BYOK 也要订阅」模式。

**例外**：开源用户 / 个人爱好者 / 重度自托管用户可以走"GitHub Sponsors 等价订阅"路径（这个机制要看 dong4j 是否愿意搭建）。

---

## 8. 待决策项（dong4j 拍板用）

> 标记 ⚠️ 的条目需要 dong4j 明确选择后才能进入 StoreKit 2 实施阶段。

### ✅ D-1：CloudKit 多端同步归免费还是 Pro — **已拍板 2026-06-18**

> 决策：**归 Pro**；**v1 首版不实现 CloudKit**。详见 `docs/StoreKit订阅上架方案.md` §2、§3。

**dong4j 选择**：选项 B（Pro）+ v1 整块延后。

- v1：无 iCloud entitlement、无同步代码；
- 后续：CloudKit 上线时设置页「启用 iCloud 同步」需 Pro 权益；
- 技术预研仍见 `docs/CloudKit数据同步设计.md` §10（每 GitHub 账号独立 Zone）。

~~选项 A（免费）~~、~~选项 C（单向免费 / 双向 Pro）~~ — 未采用。

### ⚠️ D-2：AI 标签 / 摘要试用次数

**选项 A**：3 次（推荐）—— 够看一次效果，不够形成依赖。
**选项 B**：10 次 —— 体感更完整。
**选项 C**：0 次（硬墙）—— 简单粗暴。

### ⚠️ D-3：免费版标签数量上限

**选项 A**：20 个（推荐）—— 类比 Bear。
**选项 B**：50 个 —— 更宽松。
**选项 C**：无限（用其他维度限制） —— 标签不是核心 Pro 维度。

### ⚠️ D-4：BYOK 用户是否仍需 Pro 订阅

**选项 A（推荐）**：需要 —— 参考 §7.3。
**选项 B**：不需要 —— 走"Lifetime Free for BYOK"的开发者友好路线。

### ⚠️ D-5：自动后台 AI 整理（HOM-126）是否提供"单次手动触发"给免费用户

**选项 A**：完全禁用（一致性）
**选项 B（推荐）**：免费用户可以**手动触发一次**（最多处理 5 个未分类 repo），但**自动调度（启动/同步/24h）= Pro**

理由 B：让免费用户能"看到 AI 整理的效果一次"，降低升级心理门槛。

### ⚠️ D-6：Apple 生态集成（菜单栏 / Spotlight / Shortcuts / Widget）的免费/Pro 边界

**选项 A**：全部免费（macOS 用户基础体验，原则①）
**选项 B（推荐）**：基础集成免费，**AI 唤起类**（Shortcuts "用 AI 总结" / Spotlight "AI 智能找" / Widget "今日 AI 推荐"）归 Pro

### ⚠️ D-7：AI Discovery（Show HN 抓取）的免费/Pro 边界

后端是 starcat-weekly-api，已实现自动抓取 + LLM 分类。客户端**未开始**。

**选项 A**：全部 Pro —— 依赖后端服务 + LLM 分类（原则③）
**选项 B（推荐）**：列表浏览免费（与 Trending 一致），AI 分类标签 / 单条详情的 AI 摘要 Pro

### ⚠️ D-8：浏览器伴侣 Chrome 插件免费/Pro 边界

**选项 A**：全 Pro（高级集成）
**选项 B**：登录态同步 + 一键 Star + 跳转 App 免费，AI 总结 + 跨站采集 Pro

---

## 9. 与现有文档的差异对账

### 9.1 与 `docs/需求分析.md` §7 的差异

| 项 | 需求分析 §7 | 本文档建议 | 差异原因 |
|---|---|---|---|
| AI 语义搜索 | Pro | Pro ✅ | 一致 |
| AI 摘要 / 标签 | Pro | Pro ✅ | 一致 |
| Release 订阅追踪 | Pro | Pro ✅ | 一致 |
| CloudKit 同步 | 未明示 | 待决策（D-1） | 需要补充 |
| AI 每日推荐 | Pro | **Trending 列表免费 / AI 摘要 Pro** | 拆分粒度更细 |
| AI 浮动窗口 / 对话历史 | 未提及（旧文档） | Pro | 新增功能 |
| AnySearch Web 检索 | 未提及 | Pro | 新增功能 |
| AI 自动整理（HOM-126） | 未提及 | Pro | 新增功能 |
| RepoContextPacker | 未提及 | Pro | 新增功能 |
| README 翻译 | 未提及 | Pro | 新增功能 |
| 用户分享卡片 + Starred 导出 | 未提及 | 免费 | 一次性产物 |
| 自建服务模式 | 免费（但需 Pro） | Pro（D-4 待决策） | 收紧 |

### 9.2 与 `docs/功能清单.md` §7 的差异

`功能清单.md` §7 简化版本（免费 / Pro / BYOK 三栏），本文档把 BYOK 收编到 Pro 的子模式（D-4 待决策），不再单列。

---

## 10. 实施路径建议

> 拍板结果见 **`docs/StoreKit订阅上架方案.md`**。以下为功能边界参考；StoreKit 代码实施需 dong4j 明确「开干」后启动。

### 10.1 短期（StoreKit 2 接入前 1 个月）

1. dong4j 在 §8 待决策项打钩 / 修订；
2. 根据决策更新 `docs/功能清单.md` §7 和 `docs/需求分析.md` §7 的定价方案章节；
3. 新增 `Starcat/Core/Subscription/` 目录预留（暂不写代码）；
4. 在 `AppSettings.swift` 加 `isProUser: Bool`（开发期固定 `true` 让 PR 进度不阻塞）；
5. 设计付费墙 UI 草稿（参考 Bear / Things 弹窗样式）。

### 10.2 中期（StoreKit 2 接入）

1. 实现 StoreKit 2 + 订阅状态管理 + 14 天试用 + 恢复购买；
2. 把 §6 数量限制矩阵落代码：在 AI 调用入口 / Release 订阅入口 / 标签创建入口加 `requirePro()` 检查；
3. 在已实现功能加付费墙（**注意**：已经被早期用户使用的功能要做平滑过渡，给老用户**永久免费**所有当前 Pro 功能——避免体感倒退）；
4. App Store Connect 创建 Pro 订阅 SKU。

### 10.3 长期（上架后迭代）

1. 监控转化率（免费 → 试用 → Pro），调整 §6 数量上限；
2. 根据用户反馈调整 §5 / §6 的功能边界；
3. 教育/开源/学生折扣方案落地。

---

## 11. 关联文档

- `docs/功能清单.md` § 7 定价方案（待按本文档结论更新）
- `docs/需求分析.md` § 7 定价策略建议（待按本文档结论更新）
- `docs/概要设计.md` § 4.1 AI 调用模式（已明确"两种模式均需 Pro 订阅"）
- `docs/StoreKit订阅上架方案.md`（**v1 StoreKit 拍板 + 技术方案，优先阅读**）
- `docs/工程进度/功能实现总览.md` § 5.3 订阅系统（StoreKit 2 接入项）
- `docs/AI代理API设计.md`（AI 后端代理设计）
- `docs/CloudKit数据同步设计.md`（CloudKit 同步设计）

---

*文档创建：2026-06-15 by AI 协作梳理 (Claude Opus 4.7)*
*下一次更新：dong4j 在 §8 待决策项拍板后*
