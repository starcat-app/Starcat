# Starcat Companion Chrome 插件 — 最终需求方案

> **状态**：需求确认（2026-06-13），等待 dong4j 拍板未决项后进入施工
> **关联**：
> - 初稿（已弃用）：`docs/需求讨论/chrome插件-需求初稿.md`（1041 行 v0，写于不掌握 Starcat 现状的前提，存在大量越界）
> - 详细设计：`docs/3-设计/详细设计/23-Chrome-插件方案.md`（v1.0，承担本方案的技术实现层）
> - 上下游设计：`16-活动页设计.md` / `21-weekly-api-后端3源聚合改造.md` / `22-weekly-客户端3源聚合对接.md` / `18-三场景共用架构.md`

---

## 文档版本演进

| 版本 | 日期 | 主要调整 | 触发 |
|---|---|---|---|
| v0（初稿） | ~2026-06 | 按"通用 Chrome 插件 + AI 助手"思路写出 12 章方案，规划 Inbox / Knowledge / Research Session / 跨站采集 / 插件内 AI 对话 等模块 | dong4j 早期发散 |
| v1 | 2026-06-13 | dong4j 明确锁定 **3 个必做功能**：① Activity 新增子分类 + 浏览器一键采集 ② 私人元数据浏览器投射（AI 摘要 + 标签）③ 浏览器触发 Starcat AI 摘要生成。基于 Starcat 现状收敛、砍掉越界、补齐合理增补 | dong4j 重写指令 |
| **v1.1（本版本）** | 2026-06-13 | dong4j 拍板 §10 未决项 4 项：Q1 子分类命名定为 **`Inbox`**（取代 v1 推荐的旧候选名）/ Q3 V0.1 **不含** README 翻译（推迟 V0.2 F10）/ Q5 F2 采集**保留 toast 3s 反馈** / Q8 F3 AI 摘要 V0.1 **只支持 `kind=repo`**。全文术语统一为 `Inbox` | dong4j 拍板 |

---

## 0. 一句话定位

> **Starcat Companion = 在浏览器里看 GitHub 时，把 Starcat 的私人元数据投到页面上；看到值得记录的项目时，一键回流到 Starcat 的 Inbox 收件箱。**

**插件**：识别 + 注入 + 唤起。
**Starcat**：所有 GitHub API、所有 AI 推理、所有持久化、所有用户数据。

---

## 1. 为什么要重写需求

初稿 v0 在不掌握 Starcat 现状的前提下写成，存在 5 处与现状严重背离：

| 初稿主张 | 现状 | 问题 |
|---|---|---|
| 新建 "Inbox / Knowledge / Clips" 独立模块 + 独立 GRDB 表 | Starcat 已有 Activity 聚合页 8 分类 + R-04 主表 `github_repos` 多源聚合 | 重复造轮子（**注**：本方案的 Inbox 是 Activity 第 9 个**子分类**，复用主表 + 既有详情页骨架，与初稿"独立模块"是同名不同实现） |
| 插件做 AI 摘要 / PR 总结 / Release 解释 | Starcat 已有完整 BYOK AI 链路（18+ provider / `ai_summaries` 表 / 流式摘要 / 自动后台整理） | 体验割裂、配置分裂、API Key 安全边界模糊 |
| 浏览历史智能归类 | Starcat 明确"保守 AI"原则——不经用户确认绝不动数据 | 隐私敏感 + 违反产品价值观 |
| Research Session（调研主题 / 决策记录） | 需要浏览历史采集 + 决策模型 + 跨源聚合 UI | 收益不确定、ROI 不足、隐私敏感 |
| 几乎没提反向链路（App → 浏览器） | StarredRegistry / 标签 / 笔记 / 阅读状态 / Release 订阅 / AI 摘要 全部齐备但只活在 App 内 | **最大价值被遗漏**——这恰恰是浏览器插件唯一无法被 App 替代的能力 |

> 初稿的核心错误在于把插件当成"另一个 GitHub 增强工具"。本方案把插件当成"Starcat 私人空间的浏览器分身"。

---

## 2. Starcat 现状摘要（影响插件设计的部分）

只列与浏览器侧设计有判定影响的事实，详情见 `docs/功能实现总览.md`。

| 维度 | 现状 | 对插件设计的影响 |
|---|---|---|
| Activity 聚合页 | 已上线 8 个具体分类（`announcement / release / star / repository / following / suggestion / weekly` + 规划中的 `discovery`），固定分类，本地聚合，复用 `RepoMetadataHeaderView` 详情页 | 浏览器采集天然作为新分类 `Inbox` 接入，复用既有侧栏 + 详情页骨架，零新视图 |
| R-04 主表 `github_repos` | 后端已规划主表 + `source_types` 数组（含 weekly / zread / discovery / trending / ...），客户端已对接（详见 §3.9.6 / 22 文档） | 浏览器采集作为新 source_type `clip` 与其他 4 源完全对等，零架构成本 |
| StarredRegistry | `@MainActor @Observable` 单一信任源，4 详情页统一按 `registry.contains(ghRepoId:)` 派生"私人功能可见性" | 反向链路查"是否已 star" 直接读 registry，秒级一致 |
| 私人元数据 | `tags` / `repo_notes` / `repo_status` / `release_subscriptions` / `ai_summaries` 5 套已就绪（含 source_hash 缓存机制） | 反向链路投射的全部"原料"齐备，只缺一条外送通道 |
| BYOK AI 链路 | `RepoAIInsightService` 流式摘要 + 标签推荐 + JSON mode + 缓存命中；`ReadmeTranslationService` 5 语言翻译；`AutoTidyScheduler` 自动后台整理；18+ provider 已支持 | 插件 **只触发**，所有推理 / 缓存 / 重试 / 错误处理全留 App |
| 4 后端 Go 服务 | 统一 envelope + Bearer Auth + `/api/v1/ping` 模板；客户端通过 `Core/Network` 各 actor 接入 | 插件本地 HTTP 服务沿用同款契约（Swift 平移），降低认知负担 |
| Token 存储 | AES-GCM 加密本地文件 `credentials.json`，不走 macOS Keychain | 插件**严禁**接触任何 token，**永远**只在 App 加密文件里 |
| Deep Link | URL Scheme `starcat://` 已规划但未全量实现，路由器待施工时统一扩展 | 本方案落地时一并扩展 5 个 action 路由 |

---

## 3. 核心定位与三个闭环

插件围绕三个闭环展开。**前两个闭环来自 dong4j 钦点的必做功能**，第三个是技术上自然延伸出来、收益最大的差异化能力。

### 3.1 闭环 A：Inbox 收件箱（正向，dong4j 钦点 #1）

```
浏览 GitHub repo（含未 star、未在本地 DB 的项目）
    ↓
点击插件浮按钮的「采集到 Starcat」 / 弹窗主按钮 / 右键菜单
    ↓
starcat://capture?fullname=owner/repo&source=clip
    ↓
Starcat App
  ├── 写入 R-04 主表 github_repos（source_types 追加 "clip"）
  ├── 该 repo 落入 Activity → Inbox 子分类
  └── 自动跳转该 repo 详情页
    ↓
用户在 Starcat 内可对该 repo 使用 全套能力：
  star / 标签 / 笔记 / AI 摘要 / Release 订阅 / 翻译 / ...
```

**痛点**：当前要把"浏览器看到的新项目"放进 Starcat，必须 ① 切到 GitHub 点 star → ② 等下次同步 → ③ 切回 Starcat 找它。流程长达 30~60s，且必须先 star（污染 GitHub 个人 star 列表，这与"我只是想暂存研究一下"的语义不符）。

**价值**：

1. **不污染 GitHub star 列表**：Inbox 是 Starcat 私人空间的"收件箱"，不调 `PUT /user/starred`，不动用户的 GitHub star 配额。
2. **秒级回流**：浏览器一键采集到 Starcat 内可见，<3s 完成。
3. **与 R-04 主表对齐**：复用同一张 `github_repos` 主表 + `source_types` 数组，与 weekly / zread / discovery / trending 完全对等，零新表。
4. **下游全部贯通**：采集后的 repo 走 `RepoDetailScaffold` 详情页骨架，**自动获得** Tags / Notes / Release / AI 摘要 / 翻译 等 全部 Starcat 能力。

**Activity 第 9 个子分类的命名（已拍板）**：

> **dong4j 2026-06-13 拍板：分类名定为 `Inbox`**（中文"收件箱"），R-04 source_type 仍叫 `clip`（与后端命名对齐）。

两层概念的分工：

- **R-04 source_type = `clip`**：数据源标识，粒度=浏览器采集（与 `weekly` / `zread` / `discovery` 同级）
- **Activity 分类 = `Inbox`**：用户视角的"收件箱"，规则 = `source_types` 包含 `clip`、或未来 `manual` / `share-ext` 等任何"用户主动输入"的源

**与初稿 v0 命名的关系**：初稿 v0 也用了 "Starcat Inbox" 一词，但当时把它**设计成独立模块 + 独立数据表**，本方案把 Inbox **收敛为 Activity 第 9 个子分类**——同一术语，但实现路径完全不同（零新表、复用主表 + 既有详情页骨架）。在 §1 表格里"独立 Inbox 模块"是初稿越界点，**本方案的 Inbox 不属于此越界**。

### 3.2 闭环 B：私人元数据浏览器投射（反向，dong4j 钦点 #2）

```
GitHub 页面（任意 repo 的 README / Issues / PRs / Releases / Code 子页）
    ↓
插件 content script 扫到 owner/repo
    ↓
fetch http://127.0.0.1:5051/local/v1/state?fullname=owner/repo
    ↓ Bearer Auth
Starcat App 本地 HTTP 服务返回私人元数据
    ↓
GitHub 页面 README 上方注入「Starcat 私人胶囊」
    ├── ✓ 已 star（绿）/ ☆ 未 star / ✚ 已采集到 Inbox
    ├── 标签 chips（≤3 个，溢出折叠 +N）
    ├── 阅读状态（未读 / 在读 / 在用 / 废弃）
    ├── Release 订阅徽章（含未读数）
    ├── 笔记首行（≤80 字符截断，hover 显示完整）
    └── 最近 AI 摘要首句（≤80 字符截断，hover 显示完整）
```

**痛点（dong4j 原话核心）**：
> 「我两个月前是不是 star 过这个？打了什么标签？以前评估过吗？AI 帮我写过摘要吗？」
>
> 用户在 GitHub 看 README 时，App 是后台进程；切到 App 找私人元数据 = 50% 概率懒得切 = 信息丢失。

**价值**：

1. **同类工具完全没做**：Stars Manager / Star Track / GitHub 官方 List 都没有把"个人对该项目的历史评估"投到浏览器页面上的能力——**这是 Starcat 唯一的差异化护城河**。
2. **零新数据，纯渲染**：所有展示数据都来自 Starcat 已落库的 5 张表（`stars` / `tags` / `repo_notes` / `repo_status` / `release_subscriptions` / `ai_summaries`），插件只是 fetch + 渲染。
3. **AI 摘要与标签 = 投射的两个最强字段**（dong4j 钦点的核心）：
   - 标签 = 用户对该项目的"分类决策"，看到就能立刻识别项目在自己知识体系的位置
   - AI 摘要首句 = 用户曾经委托 AI 评估过的浓缩结论，比官方 README 的 marketing 文案更贴自己

### 3.3 闭环 C：浏览器触发 Starcat AI 摘要生成（dong4j 钦点 #3）

```
GitHub repo 页面（无论 star 与否）
    ↓
插件浮按钮 / 弹窗显示「✨ 生成 AI 摘要」按钮
    ↓
点击 → starcat://summarize?fullname=owner/repo&kind=repo
    ↓
Starcat App 路由解析
    ├── 若该 repo 不在本地 DB → 先入 Inbox 分类（隐式 capture）
    ├── 唤起 RepoAIWindowController（已有的 AI 浮窗）
    └── 触发 RepoAIInsightService.generateInsight(...)（已有的流式摘要）
    ↓
AI 摘要 + 推荐标签 流式生成 → 落 ai_summaries 表
    ↓
完成后 系统通知 + 浏览器侧 F2 胶囊 自动刷新（60s 缓存到期或主动重 fetch）
```

**痛点**：
> 浏览器看到一个新项目（可能未 star），想让 AI 帮看一眼适不适合。当前必须 ① 切 App → ② 找 repo（如果没 star 还得先 star） → ③ 点 AI 入口 → ④ 等结果。

**价值**：

1. **跨"采集 + 摘要"的双重动作合一**：未 star、本地没缓存的 repo 也能直接触发 AI——App 端先隐式 capture 入 Inbox，再 enqueue AI 摘要。
2. **零摘要逻辑落到插件侧**：插件只触发 deep link，所有推理 / 流式 / 标签推荐 / 缓存命中 / 错误处理 / API Key 解析 全部走 Starcat 既有 BYOK 链路（`RepoAIInsightService` / `AISummaryRepository` / `AIClient`）。
3. **结果可见性双通道**：① App 内 AI 浮窗实时流式可见 ② 浏览器侧 F2 胶囊在摘要落库后自动刷出"最近 AI 摘要首句"——形成正反馈："我刚让 Starcat 摘了，再回到 GitHub 页面就能看到结果"。

### 3.4 三个闭环的相互放大

```
        ┌──────────────────────────────────────┐
        │  闭环 A：Inbox 收件箱（正向）            │  采集
        │   GitHub → Starcat                   │  ──→
        └──────────────────────────────────────┘
                          ↓ 入主表
        ┌──────────────────────────────────────┐
        │  闭环 C：触发 AI 摘要（正向）            │  生成
        │   浏览器 → Starcat AI 引擎              │  ──→
        └──────────────────────────────────────┘
                          ↓ 落 ai_summaries
        ┌──────────────────────────────────────┐
        │  闭环 B：私人元数据投射（反向）           │  反哺
        │   Starcat → GitHub 页面               │  ←──
        └──────────────────────────────────────┘
```

**用户故事 (黄金路径)**：
1. 浏览器看到 `vercel/next.js` 新版本的发布页，**胶囊显示** 已 star + 标签 [前端框架] + 笔记首行"v14 之后路由改动需要测"。✅ 闭环 B 触发
2. 点胶囊上的 ✨ 触发 **AI 总结 Release Notes**（V0.2 功能），App 流式生成"升级风险评估"。✅ 闭环 C 触发
3. 转到 `pmndrs/zustand` 的 README 页（**未 star、本地无记录**），胶囊显示 ☆ 未 star。一键 **采集到 Inbox** + 同时触发 **AI 摘要**——同一个动作触发两个闭环。✅ 闭环 A + C 串联
4. 30s 后再刷新该 GitHub 页面，胶囊已变为 "✚ 在 Inbox + 摘要：'轻量状态管理库，react 生态，无 boilerplate'"。✅ 闭环 B 反哺闭环 A/C 的成果

---

## 4. MVP 功能清单（V0.1）

### 4.1 必做 6 项

> dong4j 钦点 3 项 + 配套 3 项（角标 / 浮按钮 / 右键菜单都是与上述 3 个闭环共享数据通路、技术成本极低、用户感知极强的延伸）。

| 编号 | 名称 | 闭环归属 | dong4j 钦点 | 工程成本 |
|---|---|---|---|---|
| **F1** | GitHub 页面注入「Starcat 私人胶囊」（含 AI 摘要 + 标签） | 闭环 B | ✅ #2 | 中（content script 注入 + DOM 容错 + 60s 缓存） |
| **F2** | 一键采集到 Activity → Inbox 分类 | 闭环 A | ✅ #1 | 中（Activity 加分类 + R-04 source_types += clip + deep link 路由） |
| **F3** | 触发 Starcat AI 摘要生成（含未 star 项目隐式 capture） | 闭环 C | ✅ #3 | 低（只新增 deep link action，AI 链路全复用） |
| **F4** | 浏览器图标角标（已 star / 未读 release 数 / App 离线） | 闭环 B | 配套 | 低（与 F1 共享 `/local/v1/state` 接口） |
| **F5** | 右键菜单：选中文本追加到 repo_notes | 闭环 A | 配套 | 低（deep link `capture-note` + RepoNoteRepository.append） |
| **F6** | GitHub 页面右下角浮按钮（统一交互入口） | 闭环 A/B/C | 配套 | 低（4 个固定动作：在 Starcat 中打开 / 采集 / 追加笔记 / 复制 deep link） |

### 4.2 F1 详细需求：私人元数据胶囊

**触发场景**：用户打开 `github.com/{owner}/{repo}` 任意子页（README / Issues / PRs / Releases / Code）。

**注入位置**：README 标题正上方独占一行（容器选 README 上方而非 About 区——README 的 DOM 结构是 GitHub 最稳定的容器之一）。

**胶囊内容**（横向单行，可折叠）：

```
[ ✓ 已 star ]  [ #前端框架 #SSR +2 ]  [ 在用 ]  [ 🔔 2 ]  [ 📝 v14 之后路由改动需要测 ]  [ ✨ 轻量状态管理库,react 生态... ]  [ ⚙ ]
   状态点         标签 chips           阅读状态    Release    笔记首行 ≤80 字符 hover 全文     AI 摘要首句 ≤80 字符 hover 全文   设置/折叠
```

**可见性规则**：

| 条件 | 显示 |
|---|---|
| 该 repo 已 star（在本地 DB） | 胶囊全量显示 |
| 该 repo 已采集到 Inbox（未 star，但本地有 source_types ⊇ {clip}） | 胶囊全量显示 + 状态点显示 ✚ 已采集 |
| 该 repo 本地无任何记录 | 胶囊缩为单一行动按钮：「采集到 Starcat」+「✨ 生成 AI 摘要」 |
| Starcat App 未启动（127.0.0.1:5051 不可达） | 胶囊**不显示**，浏览器图标角标变灰 |

**关键约束**：

1. **胶囊不调任何 GitHub API**——所有展示数据都来自 Starcat App 的 `/local/v1/state` 接口
2. **隐私**：胶囊数据**不离开浏览器进程**（不 sync、不上传），关闭 tab 即清理；插件内存缓存 60s（同一 tab 切 PR / Issue 子页面时不重复 fetch）；切换不同 repo 立即重 fetch
3. **用户可在插件设置里关掉特定字段**（如不想显示笔记首行）
4. **数据精简化**：笔记首行 / AI 摘要首句 都做 ≤80 字符截断，避免敏感信息批量出窗口

### 4.3 F2 详细需求：一键采集到 Inbox 分类

**入口**：① 插件 toolbar popup 主按钮 ② F6 浮按钮的「采集到 Starcat」 ③ 右键菜单"Starcat：采集此 repo"。

**触发**：`starcat://capture?fullname=owner/repo&source=clip`

**App 端逻辑**：

```
1. 解析 fullname
2. 查 R-04 主表 github_repos.findByFullName(fullname)
   ├── 命中：UPDATE source_types = source_types ∪ {clip}, last_seen_at = NOW()
   └── 未命中：先调一次 GitHub /repos/{o}/{r} enrich 元数据
       ├── 成功：写入 github_repos + source_types = ['clip']
       └── 失败（网络断 / 404 / rate limited）：仍写入 source_types = ['clip']，
                                              元数据等下次 sync 自动 enrich
3. 自动跳转 → Activity → Inbox 分类 → 该 repo 的详情页（RepoDetailScaffold）
4. 浏览器侧浮 toast「已采集到 Inbox」3s（Q5 已拍板=显示，App 唤起切换有延迟用户需要确认）
```

**Activity 侧改造**（详细设计见 23 文档 + 16 文档增量）：

| 项 | 改造点 |
|---|---|
| `ActivityCategory` enum | 新增 `case inbox`，rawValue `"inbox"`，systemImage `"tray.and.arrow.down"`，iconColorHex 取 Linguist 调色板未占用色（建议 `#bf5af2` Apple Purple） |
| Sidebar 列表 | Activity root 下追加一行（与 weekly / discovery 同级） |
| `ActivityViewModel` | 加 `.inbox` 分支：从 R-04 主表筛选 `source_types ⊇ {clip}` 的 repo，按 `last_seen_at DESC` 排序 |
| 详情页 | 复用 `ActivityRepoDetailScaffoldShell`，无需新视图 |
| i18n | `activity.category.inbox` en/zh-Hans 双语 |
| 排序与去重 | 已 star + 已采集到 Inbox 的 repo 在 Inbox 分类里 **仍展示**（语义=用户曾通过浏览器关注过它），但通过来源标识区分 |

**关键约束**：

1. **采集 ≠ Star**：本动作**绝不调** `PUT /user/starred`。这是 Inbox 与"一键 Star"的本质区别，避免污染用户 GitHub 个人 star 列表。
2. **已 star 的 repo 也可重复"采集"**：等于"标记最近浏览过"，更新 `last_seen_at`，不重复创建。
3. **若用户后续在 Starcat 内选择"Star 这个项目"**：走标准 star API → 同步成功后该 repo `is_starred=true`，但仍在 Inbox 分类（直到用户手动从 Inbox 移除——后续可加移除入口）。

### 4.4 F3 详细需求：触发 Starcat AI 摘要生成

**入口**：① F1 胶囊的 ✨ 按钮 ② F6 浮按钮的「✨ 生成 AI 摘要」 ③ Toolbar popup 在 GitHub repo 页时的副按钮。

**触发**：`starcat://summarize?fullname=owner/repo&kind=repo`

**App 端逻辑**：

```
1. 解析 fullname + kind
2. 检查本地 DB
   ├── 已存在（已 star 或 已 capture）：直接进入步骤 3
   └── 不存在：先隐式执行 capture（与 F2 同款逻辑：enrich + source_types=['clip']）
3. RepoAIWindowController.show(for: repo)（已有的 AI 浮窗）
4. RepoAIInsightService.generateInsight(repo:, force: false)（已有的流式摘要）
   ├── 缓存命中（source_hash 未变 + 同 model）：直接展示已缓存摘要
   └── 缓存未命中：触发流式生成 → 落 ai_summaries 表
5. 完成后：
   ├── App 内 AI 浮窗实时展示（既有体验，零改动）
   ├── 系统通知（既有 ReleaseNotificationService 同款 UNUserNotificationCenter）
   └── 浏览器侧 F1 胶囊在 60s 缓存到期后自动刷出新 AI 摘要首句
```

**关键约束**：

1. **不在插件侧做任何 AI 调用**：所有推理走 Starcat 既有 BYOK 链路。
2. **隐式 capture 是双闭环串联**：未 star 项目"想让 AI 看一眼"= 自然产生 Inbox 数据，符合用户心智「先收藏再细看」的工作流。
3. **AI 摘要默认范围**：当前实现的 `RepoAIInsightService` 输入是 repo metadata + README 缓存，**不读 Issues / PRs**。F3 V0.1 复用该范围（`kind=repo`）。`kind=issue` / `kind=pr` / `kind=release` 留 V0.2（详见 §6）。
4. **流式摘要是用户感知的核心体验**：现有 `RepoAIChatViewModel` 已支持流式渲染，F3 V0.1 不改这条链路。
5. **缓存命中时不重复扣 AI 配额**：`source_hash` 由 repo 元数据 + README 文本生成，未变就直接展示——这是 dong4j 已落地的"自动后台整理"使用的同一机制。

### 4.5 F4 浏览器图标角标

**规则**：

| 当前 tab | 角标 |
|---|---|
| GitHub repo 页 + 已 star + 无未读 release | 🟢（不显示数字） |
| GitHub repo 页 + 已 star + 有未读 release | 🔴（显示数字，>9 显示 9+） |
| GitHub repo 页 + 已采集到 Inbox（未 star） | 🔵 |
| GitHub repo 页 + 本地无记录 | ⚪ |
| GitHub repo 页 + Starcat App 未启动 | 灰色（禁用态） |
| 非 GitHub repo 页 | 无角标 |

**实现**：service worker 监听 `chrome.tabs.onActivated` + `chrome.tabs.onUpdated`，按当前 tab URL 决定是否 fetch `/local/v1/state`（与 F1 共享接口、共享 60s 缓存）。

### 4.6 F5 右键菜单：追加笔记

**触发**：仅在 `github.com/{owner}/{repo}/*` + 用户选中文本时，右键菜单出现 "Starcat：追加到笔记"。

**触发链路**：`starcat://capture-note?fullname=...&text=<urlencoded>`

**App 端逻辑**：

```
1. 解析 fullname + text
2. 检查本地 DB（与 F3 同样的策略）
   ├── 已存在：直接进入步骤 3
   └── 不存在：先隐式 capture
3. RepoNoteRepository.find(repoId:) ?? RepoNoteRepository.create(empty)
4. RepoNoteRepository.append("\n\n> 来自浏览器：{当前页 URL}（YYYY-MM-DD HH:MM）\n{选中文本}")
5. 后台静默完成（不强制跳详情页），系统通知"已追加到 owner/repo 笔记"
```

**约束**：

- 选中文本超过 2000 字符时插件侧截断 + 提示
- 追加格式固定（带来源 URL + 时间戳）便于用户后续检索
- 不做 AI 摘要，纯文本追加

### 4.7 F6 GitHub 页面右下角浮按钮

**位置**：GitHub repo 页面右下角（24×24 半透明圆形按钮，不抢视觉），仅在 `/{owner}/{repo}` 主页和 README 子页显示。

**Hover 展开 4 项**：

| 动作 | 触发 | 备注 |
|---|---|---|
| 🐱 在 Starcat 中打开 | `starcat://repo?fullname=...` | 唤起 App 进入对应详情页 |
| ✚ 采集到 Starcat | `starcat://capture?fullname=...` | F2 入口 |
| 📝 追加笔记 | 弹文本框 → `starcat://capture-note?...` | 与 F5 等价但允许用户手动输入而非选中 |
| 📋 复制 deep link | `navigator.clipboard.writeText('starcat://repo?...')` | 便于发给同事、跨设备同步链接 |

**约束**：

- 浮按钮位置可拖拽 + chrome.storage.local 持久化
- 用户可永久隐藏（设置开关）
- 不在 Issue / PR / Release 子页显示（避免与 GitHub 自带按钮抢位置）

---

## 5. 双向通信通道

### 5.1 正向链路（浏览器 → App）：URL Scheme 5 个 action

| Deep Link Action | 触发场景 | 对应 MVP |
|---|---|---|
| `starcat://repo?fullname=owner/repo` | "在 Starcat 中打开" | F6 |
| `starcat://capture?fullname=owner/repo&source=clip` | "采集到 Inbox" | F2 / F6 |
| `starcat://capture-note?fullname=...&text=<urlencoded>` | "追加到笔记" | F5 / F6 |
| `starcat://summarize?fullname=...&kind=repo` | "✨ 生成 AI 摘要" | F3 |
| `starcat://translate-readme?fullname=...` | "翻译 README"（V0.2） | V0.2 F10 |

**统一参数规范**：

- `fullname` 永远使用 `owner/repo` 字面量（GitHub 显示形态），App 端用 case-insensitive 规则匹配本地 DB
- URL / 选中文本必须用 `encodeURIComponent`，不允许直接拼接
- 每个 action 携带 `version` 参数让 App 端做向后兼容判定

### 5.2 反向链路（App → 浏览器）：本地 HTTP 服务

**地址**：`http://127.0.0.1:5051/local/v1/*`（端口冲突时 App 自动探测 5051~5060）

**鉴权**：Bearer Token（首次启动 App 生成、写入 `~/Library/Application Support/Starcat/companion.token`，与 `credentials.json` 同目录加密；用户在「设置 → Companion」可看可重置）

**端点最小集（V0.1 仅 2 个）**：

| 端点 | 用途 | 备注 |
|---|---|---|
| `GET /local/v1/ping` | 健康检查 + schema_version 协商 | 与 4 后端 ping 同语义；插件首次安装握手用 |
| `GET /local/v1/state?fullname=owner/repo` | F1 / F4 共享：返回 isStarred / isClipped / tags / status / notesExcerpt(≤120) / releaseSubscribed + unreadReleaseCount / latestAISummaryExcerpt(≤200) | 单接口聚合返回，避免插件多次请求 |

**V0.2 增量端点**：`POST /local/v1/capture`（省去拉起 App 的 toast 体验）/ `POST /local/v1/note/append` / `GET /local/v1/state-batch?fullnames=a/b,c/d,...`（trending 行内批量增强用）。

详细的端点 schema、CORS 规则、Manifest 权限申请要点见 `23-Chrome-插件方案.md` §6。

---

## 6. 路线图（V0.2 / V0.3）

> dong4j 已锁定 V0.1 范围；V0.2 / V0.3 是建议，最终按 V0.1 上线后用户行为决定优先级。

| 阶段 | 功能 | 复用现有能力 | 预估工期 |
|---|---|---|---|
| **V0.2** | F7：Issue / PR / Release Notes 一键 AI 总结 | 复用 `RepoAIInsightService`，新增 prompt template（issue / pr / release-risk），扩展 `kind` 参数 | 1 周 |
| V0.2 | F8：Release 升级风险解释 | 同 F7 | 0.5 周 |
| V0.2 | F9：Trending 页面行内增强（github.com/trending 每行叠 ✓ / 标签） | 复用 `/local/v1/state-batch` 批量端点 | 0.5 周 |
| V0.2 | F10：README 翻译触发 | 复用 `ReadmeTranslationService`（HOM-68 已上线） | 0.3 周 |
| V0.2 | F11：插件设置页内置「测试 Starcat 连接」 | 复用 ping 端点 + R-03 单步 ping 体验 | 0.3 周 |
| V0.3 | F12：跨站采集（HN / Reddit / 技术博客 → Activity Discovery） | 等 R-04 主表 + Discovery 流水线稳定 | 2 周 |
| V0.3 | F13：Repo 对比候选（浏览器收集 → App 对比页） | 依赖 P2 AI 高级"对比报告"功能 | 配套 |
| V0.3 | F14：Firefox / Safari 扩展 | 视用户需求决定 | 评估后定 |
| 评估 | F15：Research Session（调研主题 / 来源 / 决策） | 隐私敏感 + 模型成本 | 先观测 V0.1/V0.2 用户行为再决定 |

---

## 7. 明确不做

为防止"插件做太多 → 与 App 体验分裂 → 维护成本爆炸"，先把边界写死。

| 项 | V0.1 | V0.2 | 永不做 | 原因 |
|---|---|---|---|---|
| 插件内 AI 对话 | ❌ | ❌ | ✅ | 复制 BYOK 配置 = 体验割裂 + API Key 安全边界模糊 |
| 浏览历史智能归类 / 自动分析 | ❌ | ❌ | ✅ | 隐私敏感，违反 Starcat「保守 AI」原则 |
| 完整网页正文抽取 | ❌ | ❌ | ✅ | 解析复杂、网站差异大、低 ROI |
| 插件 fetch GitHub API | ❌ | ❌ | ✅ | 用户配额不属于插件 |
| 插件持有任何 token / API Key | ❌ | ❌ | ✅ | Token 永远只在 App 加密文件里 |
| 自动注入大量 GitHub UI（Issue 标题区按钮 / Release 页按钮 / 源码页按钮） | ❌ | ❌ | ✅ | 与 GitHub DOM 强耦合，维护成本爆炸；统一收敛到一个 F6 浮按钮 |
| Native Messaging | ❌ | ❌ | ✅ | URL Scheme + 本地 HTTP 双通道已足够 |
| 独立 Inbox / Knowledge / Clips 模块 | ❌ | ❌ | ✅ | R-04 主表 + Activity Inbox 分类已覆盖，立独立模块 = 重复造轮子 |
| Research Session | ❌ | ❌ | 评估 | 隐私敏感 + 收益不确定，先观测 V0.1 行为再评估 |
| 跨 Starcat 实例切换 | ❌ | ❌ | 评估 | 单实例对接已足够，多实例是低频长尾 |
| Issue / PR / Release Notes AI 总结 | ❌ | ✅ F7 | ✅ V0.2 | 现有 `RepoAIInsightService` 输入是 repo metadata + README，不读 Issue / PR；要做需扩 prompt 与上下文打包 |
| Trending 页面行内增强 | ❌ | ✅ F9 | ✅ V0.2 | 需要批量 state 接口，V0.1 不做 |
| README 翻译触发 | ❌ | ✅ F10 | V0.2 | dong4j 2026-06-13 拍板 V0.1 不含，推迟 V0.2 F10（见 §10 Q3） |
| Firefox / Safari 扩展 | ❌ | ❌ | V0.3 评估 | Safari 需 Xcode 项目化；Firefox MV3 兼容仍在演进；MVP 仅 Chromium 系 |

---

## 8. 与 Starcat 现有架构的对接清单

| Starcat 模块 | 插件如何复用 / 触发 | 改造点 |
|---|---|---|
| `RepoRepository` (GRDB) + R-04 `github_repos` 主表 | F2 / F3 / F5 走 capture 路径，写入 source_types += `clip` | App 端：扩 `RepoRepository.upsertFromClip(...)` 或复用既有 R-04 写入路径；零新表 |
| `StarredRegistry` (`@MainActor @Observable`) | F1 / F4 反向链路读"是否已 star" | App 端：本地 HTTP 服务直接消费 registry，零改动 |
| `RepoTagRepository` / `RepoNoteRepository` / `RepoStatusRepository` / `ReleaseSubscriptionRepository` | F1 反向链路读用户私人元数据 | App 端：本地 HTTP 服务聚合调用，零改动 |
| `AISummaryRepository` (`ai_summaries` 表) | F1 读最近摘要首句；F3 写新摘要 | App 端：复用 `fetchLatestPerRepo()` 已有方法 |
| `RepoAIInsightService` (流式摘要 + 标签) | F3 触发后由 App 调用，零改动 | 已经具备 deep link 路由后即可触发 |
| `RepoAIWindowController` | F3 触发后弹出已有 AI 浮窗 | 零改动 |
| `ReadmeTranslationService` | V0.2 F10 触发 | 零改动 |
| `RepoDetailScaffold` / `UnifiedRepoRow` / `ActivityDetailScaffoldShell` | Inbox 分类详情页直接复用 4 详情页同构骨架 | 零改动 |
| `ActivityCategory` enum | 加 `case inbox` | 单个 enum case + i18n + Sidebar 渲染分支 |
| `ActivityViewModel` | Inbox 分类的列表加载 | 加 `.inbox` 分支：从 R-04 主表筛选 source_types ⊇ {clip} |
| `Core/Network` Bearer envelope 客户端 | 本地 HTTP 服务平移 | App 端新增 Swift 嵌入式 HTTP server（SwiftNIO 或 Network.framework），契约对齐 |
| `KeychainManager`（AES-GCM 文件） | Companion Token 持久化 | 新增 `companion.token` 文件 + 设置页可读可重置 |
| Settings View | 加「Companion」分组（端口 / Token / 连接状态） | 新增 1 个 Settings tab section |
| Deep Link Router | 5 个 action 路由 | App 端：在现有 URL Scheme 注册基础上扩展 router |

> **零新表、零新视图、零新后端服务**——这是本方案与初稿最大的差异。

---

## 9. 隐私与能力边界（写入 Code Review checklist）

### 9.1 严禁项

| 严禁 | 理由 |
|---|---|
| ❌ 插件代码中出现任何 GitHub Token / Bearer Token（除 Companion Token）/ AI API Key | Token 永远只在 App 加密文件 |
| ❌ 插件 fetch `https://api.github.com/*` | 用户 API 配额不属于插件 |
| ❌ 插件代码中出现任何 LLM provider 域名（openai.com / anthropic.com / openrouter.ai 等）的 fetch | AI 推理永远在 App 内 |
| ❌ 插件持久化用户私有数据（标签 / 笔记 / 状态 / star 列表）超过 60s | 私有数据永远只在 App 加密 SQLite，插件只做"读+渲染"瞬态展示 |
| ❌ 插件采集 / 上报浏览历史 | 隐私敏感；只在用户**主动**触发动作时读取当前 tab URL |
| ❌ 插件改写或拦截 GitHub 页面原有功能 | 只**追加**胶囊，不替换、不隐藏、不劫持 GitHub 自带按钮 |

### 9.2 Manifest 最小权限

| 权限 | 用途 | 必要性 |
|---|---|---|
| `host_permissions: ["http://127.0.0.1:*/"]` | 反向链路 fetch | 必需 |
| `host_permissions: ["https://github.com/*"]` | F1 / F4 / F6 GitHub 页面注入 | 必需，仅限 github.com 不要泛 |
| `contextMenus` | F5 右键菜单 | 必需 |
| `storage` | Companion Token + 偏好 | 必需，仅 chrome.storage.local 不 sync |
| `activeTab` | 读当前 tab URL | 必需，配合用户主动点击 |

**不申请**：`tabs` / `webRequest` / `webNavigation` / `history` / `downloads` / `<all_urls>`——这些是 Chrome Web Store 审核敏感权限，多一项审核多一道卡点，且会给用户造成"重权限插件"的不安全感。

### 9.3 降级策略

| 场景 | 表现 |
|---|---|
| Starcat App 未启动 | F1 胶囊不显示 / F4 角标灰 / F2/F3/F5/F6 仍可触发 deep link（macOS 自动唤起 App） |
| Companion Token 错误或被重置 | F6 浮按钮提示"请到 Starcat → 设置 → Companion 复制最新 Token" |
| 插件 + App 版本不匹配 | `/local/v1/ping` 返回 `schema_version`，插件不兼容时浮提示"请升级 Starcat App / 插件" |
| 端口冲突（5051 被占） | App 启动探测 5051~5060 可用端口，写入 `companion.token` 一并持久化端口号；插件设置页读端口 |

---

## 10. 未决项（dong4j 拍板状态）

> **2026-06-13 dong4j 拍板**：Q1 / Q3 / Q5 / Q8 已定。剩余 Q2 / Q4 / Q6 / Q7 / Q9 / Q10 沿用本方案推荐倾向，开施工时若需调整再开 issue。

| 编号 | 问题 | 状态 | 结论 / 倾向 | 理由 |
|---|---|---|---|---|
| **Q1** | Activity 第 9 个分类命名 | ✅ **已拍板** | **`Inbox`**（中文"收件箱"），R-04 source_type 仍叫 `clip` | 收件箱语义清晰；与 R-04 source_type 命名分层（数据源 vs 用户视角分类） |
| **Q2** | F1 胶囊在 GitHub 注入位置 | ⏳ 倾向 | README 上方独占一行 | DOM 结构最稳定；不与其他 Star 管理插件常见的 sidebar / topbar 注入位置冲突 |
| **Q3** | V0.1 是否包含 README 翻译触发（F10 提前到 V0.1） | ✅ **已拍板** | **不包含**（推迟 V0.2 F10） | dong4j 决定 V0.1 聚焦 3 个钦点功能 + 配套，README 翻译留 V0.2 |
| **Q4** | F4 浏览器图标角标是否显示"未读 release 数" | ⏳ 倾向 | 显示 | 用户感知最强；技术成本只是 `/local/v1/state` 多返回一个数字字段 |
| **Q5** | F2 采集后是否 toast 提示 | ✅ **已拍板** | **toast 3s**「已采集到 Inbox」 | App 唤起切换有延迟，用户需要确认操作生效；与"自动跳详情页"并不冲突 |
| **Q6** | 插件命名 | ⏳ 倾向 | **Starcat Companion** | 与原方案一致，传达"配套"语义；中性、不抢 Starcat 主品牌 |
| **Q7** | 是否支持 Firefox / Safari | ⏳ 倾向 | **MVP 仅 Chromium 系**（Chrome / Edge / Arc / Brave） | Safari 需 Xcode 项目化；Firefox MV3 兼容仍在演进；Chromium 系覆盖 ≥85% 开发者用户 |
| **Q8** | F3 AI 摘要的 `kind` 参数 V0.1 范围 | ✅ **已拍板** | **只支持 `kind=repo`** | Issue/PR/Release 总结需要扩 prompt + 上下文打包，留 V0.2 F7/F8 |
| **Q9** | 反向链路 `/local/v1/state` 是否走 SSE 推送 | ⏳ 倾向 | **MVP 用 fetch + 60s 缓存** | SSE 实现复杂度高、用户切 tab 时 fetch 一次足够；状态变化"延迟 60s 可见"对用户体验无感 |
| **Q10** | Inbox 分类是否支持"从 Inbox 移除" | ⏳ 倾向 | **MVP 提供"移除"按钮**，仅 `source_types -= {clip}` 不连带删除主表数据 | Inbox 是收件箱语义需要"清理"动作；删 source_type 不影响其他源（如 weekly 仍保留） |

---

## 11. 工期与里程碑（粗估）

> **总工期 V0.1 约 3 周**（不含 Chrome Web Store 审核外部时间）。详细 M1~M8 拆分见 23 文档 §13(详见 `docs/3-设计/详细设计/23-Chrome-插件方案.md`)。

| 里程碑 | 内容 | 工期 |
|---|---|---|
| M1 | Starcat App 内嵌本地 HTTP 服务模块 + ping/state 端点 + Companion Token 持久化 + 设置页 Companion 分组 | 3~4 天 |
| M2 | Starcat App 扩展 deep link 路由（5 个 action）+ R-04 主表 `source=clip` 写入路径 + Activity Inbox 分类落地 | 2~3 天 |
| M3 | Chrome 插件项目脚手架（MV3 + content script + service worker + popup + manifest） | 2 天 |
| M4 | 插件 F1 状态镜像胶囊（content script 注入 + fetch 本地 HTTP） | 3~4 天 |
| M5 | 插件 F2 / F3 / F5 / F6（deep link 触发 + 浮按钮 + 右键菜单） | 2~3 天 |
| M6 | 插件 F4 浏览器图标角标 + service worker tab 切换监听 | 1~2 天 |
| M7 | 联调 + 文档（README + 隐私政策 + Chrome Web Store 商店描述 + 用户引导） | 2~3 天 |
| M8 | Chrome Web Store 提交审核 | 1 周（外部） |

> M1 / M3 可并行启动；M4 / M5 / M6 在 M1 / M2 / M3 全部完成后并行。

---

## 12. 收益与差异化

### 12.1 用户视角（量化）

| 场景 | 之前耗时 | 之后耗时 | 提升 |
|---|---:|---:|---|
| 浏览到一个新项目 → 记录到 Starcat | 切 App + 搜索 + 输入笔记 ≈ 30~60s | 浏览器右键采集 ≈ 1~3s | **15~30×** |
| 看一个 repo 时回忆"我之前怎么评估的" | Cmd+Tab + 找 repo + 看 notes ≈ 10s | 胶囊直接显示 AI 摘要首句 + 笔记首行 ≈ 0s | **∞** |
| 让 AI 帮看一个未 star 的新项目 | star → 切 App → 找 repo → 点 AI 入口 ≈ 30s | 浏览器一键触发 ≈ 3s（含 capture + summarize 双闭环） | **10×** |
| 长 PR / Issue 阅读（V0.2） | 手读 + 回头总结 ≈ 5~10min | 一键 AI 总结 ≈ 30s 等通知 | **10~20×** |

### 12.2 产品视角

| 维度 | 收益 |
|---|---|
| **拉新** | Chrome Web Store 流量 ≫ Mac App Store；插件是 Starcat 天然的引流入口 |
| **黏性** | 用户每天看 GitHub 即感受 Starcat 价值，不必"想起来用"——把"打开 App"的入口从 Dock 扩展到任何 GitHub 页面 |
| **数据飞轮** | Inbox 分类的高质量信号反哺 R-04 主表 source 多样性；后续可分析"哪些 clip 后来被 star 了 / 被 AI 摘要了"等行为指标 |
| **差异化护城河** | 同类工具（Stars Manager / Star Track / GitHub 官方 List）**没有任何一个**做"私人元数据浏览器投射"——这是 Starcat 多年打磨的「整理 / 理解 / 找回 / 评估」核心价值在浏览器侧的天然延伸 |
| **架构复用** | F1+F4 共享 `/local/v1/state`；F2/F3/F5/F6 共享 deep link 5 actions；零新增 GRDB 表；零新增 Starcat 视图 |

---

## 13. 风险与缓解

| ID | 风险 | 缓解 |
|---|---|---|
| R1 | 本地 HTTP 端口被占 | 探测 5051~5060；插件设置页支持手动配置 |
| R2 | Chrome 插件 fetch `http://127.0.0.1` 受 CORS / mixed content 限制 | App 端响应明确 `Access-Control-Allow-Origin: chrome-extension://<id>`；MV3 申请 `host_permissions: ["http://127.0.0.1:*/"]` |
| R3 | GitHub 改版破坏注入位置 | 选最稳定的 README 上方容器；用 `MutationObserver` 容错；版本不匹配时 F1 降级为 toolbar popup |
| R4 | Companion Bearer Token 泄漏 | 仅本地有效（127.0.0.1 不外传）；设置页提供"重置"入口；Token 与 GitHub Token 独立生成，泄漏后只能调本地服务 |
| R5 | 插件 + App 版本不匹配 | `/local/v1/ping` 返回 `schema_version`；deep link 携带 `version` 参数 |
| R6 | 用户开多个浏览器（Chrome + Edge + Arc） | 端口共享；Token 一份所有浏览器都能用 |
| R7 | App 关闭时用户点 capture | deep link 自动唤起 App（macOS URL Scheme 注册）；`/local/v1/state` 失败则不显示胶囊（自然降级） |
| R8 | 用户隐私顾虑（"插件读了我所有 GitHub 浏览历史？"） | 严格遵守 §9.2(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 最小权限；只在用户主动触发时读 tab URL；公开 README + 隐私政策清晰说明 |
| R9 | Chrome Web Store 审核驳回（权限申请过宽） | 严守 §9.2(详见 `docs/6-发版与上架/v1-上架信息准备.md`)；首发版不申请任何 `<all_urls>`、不夹带任何分析 / 统计 SDK |
| R10 | 用户已装 N 个 Star 管理插件互相冲突注入 | F6 浮按钮位置可拖拽 + 一键完全隐藏；F1 胶囊位置选保守（README 上方独占行，不与常见的 sidebar / topbar 注入冲突） |

---

## 14. 文档关联

### 14.1 落地时需同步更新的文档

| 文档 | 更新内容 |
|---|---|
| `docs/功能实现总览.md` | §5.6（已规划"浏览器伴侣"占位）改为本方案的实现追踪行；§10 变更日志加方案落档 + dong4j 拍板必做 3 项 |
| `docs/3-设计/详细设计/16-活动页设计.md` | Activity 分类章节追加 `Inbox` 子分类设计 |
| `docs/3-设计/详细设计/21-weekly-api-后端3源聚合改造.md`（R-04） | §2.4 source_types 列表的描述里增加 `clip`，与 weekly / zread / discovery 并列 |
| `docs/3-设计/详细设计/22-weekly-客户端3源聚合对接.md` | 来源标识的 source 类型列表增加 `clip` 渲染样式 |
| `docs/3-设计/详细设计/23-Chrome-插件方案.md` | v1.0 → v1.1：补本方案的 dong4j 拍板更新（Inbox 分类命名 / F3 必做 / V0.1 范围调整） |
| `docs/7-工具与脚本/Swift-学习索引.md` | 实施 M1 时若引入 SwiftNIO / Network.framework 嵌入式 HTTP server，关键概念加索引 |

### 14.2 不需要修改的文档

- `docs/3-设计/详细设计/01-数据库设计.md`（零新增表）
- `docs/3-设计/详细设计/04-技术选型.md`（浏览器侧技术栈与 Starcat 主项目正交）
- `docs/3-设计/详细设计/06-核心模块设计.md`（不动 OAuth / Sync / Repository 边界）
- 4 个后端 Go 服务 README / CHANGELOG（不动后端）

### 14.3 与初稿（v0）的关系

- **保留**：原始 `chrome插件-需求初稿.md` 不删，作为本方案的"演进对照"，便于未来 Code Review 看到为何砍掉某些功能
- **指针**：本方案文档头部已标注初稿"已弃用"，新增功能讨论从本文档开始
- **冲突**：原初稿与本方案冲突时，**一律以本方案为准**

---

## 15. 验收标准（dong4j 拍板后施工时用）

按照 CLAUDE.md / AGENTS.md 工作流，每个里程碑完成后在 `功能实现总览.md` §5.6 对应条目下追加 `> 实现：...` 行。

V0.1 验收：

- [ ] M1 完成：本地 HTTP `ping` + `state` 端点可用，Companion Token 可在设置页查看与重置
- [ ] M2 完成：4 个 deep link action（`repo` / `capture` / `capture-note` / `summarize`）可被 App 路由解析（`translate-readme` 留 V0.2 F10）；Activity 新增 Inbox 分类，sidebar 可见，能列出 source_types ⊇ {clip} 的 repo
- [ ] M3 完成：Chrome 插件可加载到 chrome://extensions（developer mode）
- [ ] M4 完成（**dong4j 钦点 #2**）：在 `github.com/vercel/next.js` 看到「Starcat 私人胶囊」显示标签 + AI 摘要首句 + 笔记首行
- [ ] M5 完成（**dong4j 钦点 #1 + #3**）：浏览未 star 项目，点击 ✚ 采集 → 跳 Starcat → Activity Inbox 列表里出现该 repo；点 ✨ 触发 AI 摘要 → AI 浮窗流式生成 → 完成后回到浏览器胶囊显示新摘要首句
- [ ] M6 完成：浏览器图标角标在已 star / 已采集 / 未 star / App 离线 4 种状态下表现正确
- [ ] M7 完成：README + 隐私政策 + 商店描述就绪
- [ ] M8 完成：Chrome Web Store 内测版上线

---

> **方案就绪状态**：本文档以 dong4j 钦点的 3 个必做功能为主线，以 Starcat 已上线的 Activity 聚合 + R-04 主表 + StarredRegistry + BYOK AI 链路 为复用基础，砍掉初稿中所有越界 / 隐私敏感 / 重复造轮子的部分，给出 V0.1 可落地的 MVP 清单 + V0.2/V0.3 路线图 + 详细对接清单。
>
> **2026-06-13 dong4j 拍板核心 4 项**：Q1（Inbox 命名）/ Q3（V0.1 不含 README 翻译）/ Q5（toast 反馈）/ Q8（kind=repo），其余 Q2 / Q4 / Q6 / Q7 / Q9 / Q10 沿用本方案推荐倾向，施工时若需调整再开 issue。**当前可启动施工。**

