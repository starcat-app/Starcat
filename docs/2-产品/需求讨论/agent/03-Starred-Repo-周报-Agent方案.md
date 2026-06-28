# Starred Repo 周报 Agent 方案

> **文档定位**: "每周自动扫一遍用户新增的 stars,生成中文周报推送"的方案。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板立项。
> **推荐度**: 🥈(见 [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md))
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`02-替代品推荐-Agent方案.md`](02-替代品推荐-Agent方案.md):共用 `AgentOrchestrator`
> - [`../CLAUDE.md`](../CLAUDE.md):NSBackgroundActivityScheduler 已有规划
> - [`../概要设计.md`](../概要设计.md):后台任务设计

---

## 一、用户故事

### 1.1 主流程

> 作为 Starcat 用户,我每周一早上打开 app,看到一张「📰 本周 Stars 周报」卡片:
> - 本周新增的 stars 数量
> - 按主题 / 语言自动聚类
> - 每个集群选 1 个 "代表项目" 给一句简介
> - 至少 1 个 "**小众但有意思**" 区块(LLM 自主挑选)
> - 我可以一键把周报保存为 note,或点进某个 cluster 看完整列表

### 1.2 触发模型

| 触发方式 | 说明 | 推荐 |
|---|---|---|
| **被动拉取**: 打开 app 时检查"上次生成周报距今 > 7 天?" | 无需后台,简单可靠 | 🥇 MVP |
| **主动推送**: `NSBackgroundActivityScheduler` 周一早上 8 点跑 | 见 `CLAUDE.md` "后台任务" | 🥈 v1.1 |
| **手动触发**: 设置页"立即生成本周周报"按钮 | 调试 / 试用 | ✅ 必备 |

**MVP 推荐**: 被动拉取 + 手动触发,**不**做后台推送(等用户量起来再加)。

---

## 二、核心价值 & 差异化

| 维度 | 现有方案 | Starcat 周报 Agent |
|---|---|---|
| GitHub Trending 周报 | 第三方邮件订阅 | **基于你个人 stars 库**,而不是大众热门 |
| Star History 类工具 | 只给图表,不给解读 | **LLM 主题聚类 + 文字解读** |
| 自动化新闻聚合(Hacker News Brief) | 全网热点 | **只关注你 star 过的项目及同类** |
| Starcat 现有 "Activity" 视图 | 显示新增 stars 原始列表 | **AI 聚类 / 摘要 / 小众发现** |

> **核心差异化**: "**个人化**的 stars 趋势解读"——你的 stars 历史就是你的兴趣画像,周报就是这种画像的周更。

---

## 三、工具集设计

### 3.1 工具清单

```
Tool 1: get_stars_in_window
  输入:  userId(隐式), fromTimestamp, toTimestamp
  输出:  本周新增的所有 repo(完整元信息)
  复用:  Starcat 已有 stars 表的 created_at 字段

Tool 2: get_repo_overview
  输入:  owner, repo
  输出:  description / stars / language / topics / last_push / readme 前 300 tokens
  复用:  Starcat 已有 RepoAIContextProvider

Tool 3: cluster_repos_by_topic
  输入:  repoList[](5-30 个), groupSizeHint(默认 5)
  输出:  分组结构:
         [
           { topic: "Rust CLI 工具", repos: [...], representative: {...} },
           { topic: "AI Agent 框架", repos: [...], representative: {...} },
           ...
         ]
  内部:  调 LLM 用 `@Generable` 结构化输出,避免 JSON 解析失败

Tool 4: find_hidden_gem
  输入:  repoList[](从 cluster 里挑的低 star 数但有趣的)
  输出:  1 个 "小众但有意思" 候选 + 一句话推荐理由
  内部:  调 LLM,prompt 强调"不只看 star 数,关注创新点"
```

### 3.2 工具 schema 关键约束

- **`cluster_repos_by_topic` 必须 5-30 个 repo**: 太少聚类无意义,太多 LLM 一次吃不下(> 30 tokens 会爆)
- **`find_hidden_gem` 候选源**应**主动筛** < 1000 stars 的 repo(否则不算"小众")
- **所有工具必须返回 ISO 8601 时间戳**,周报里显示用 locale-aware formatter

---

## 四、Agent 编排循环

### 4.1 周报生成流程

```
[Step 1] system: "你是 Starcat 周报编辑,基于用户本周新增 stars 写周报"
[Step 2] user: "生成本周 stars 周报"   (or 自动触发)
[Step 3] tool_call: get_stars_in_window(from=7天前, to=现在)
         → 假设 12 个新 star
[Step 4] tool_call: get_repo_overview(...)  // 并发拉详情,12 次
         → 12 个 repo 的元信息 + readme 摘要
[Step 5] tool_call: cluster_repos_by_topic(repoList=12, groupSizeHint=5)
         → 4 个 cluster: "Rust CLI"(3)/ "AI Agent"(4)/ "Obsidian 插件"(2)/ "其他"(3)
[Step 6] tool_call: find_hidden_gem(repoList=所有 <1000 stars 的)
         → 1 个 "本周小众之星"
[Step 7] LLM 整理: 写成 markdown 周报(标题/概述/cluster 列表/小众之星/footer)
[Step 8] final_answer → UI 渲染
```

最大步数 8 步。

### 4.2 关键设计取舍

- **`get_repo_overview` 用并发**: 12 个 repo 串行要 12× 200ms ≈ 2.4s, 并发只需 ~400ms。**但**要受 Starcat 已有 GitHub rate limit 约束(见 §6.1)
- **不做增量**: 每次全量拉本周 7 天窗口(数量小,全量简单;增量要 diff,反而复杂)
- **空周处理**: 如果本周 0 个新 star,跳过整个 agent run,UI 显示"本周没有新 star,下周见"

---

## 五、UI 落地

### 5.1 周报卡片位置

**推荐**: **主窗口右上角「铃铛」图标**(Activity 已有入口可借用)
- 无新周报: 铃铛灰色
- 有新周报: 铃铛蓝色 + 数字角标 "1"
- 单击: 弹出 `RepoAIWindowContentView` 风格的报告窗口

### 5.2 周报 markdown 结构

```markdown
# 📰 本周 Stars 周报
**2026-06-21 ~ 2026-06-27** | 12 个新 star

## 本周概览
你本周重点关注了 **AI Agent 框架**(4 个)和 **Rust CLI 工具**(3 个),
和上周的「macOS 原生开发」主题有明显转向。

## 🔥 主题 1: AI Agent 框架(4)
- **openai/swarm** (⭐ 8.2k) — 轻量级多 agent 编排
- **anthropics/claude-code-sdk** (⭐ 1.2k) — Claude Code 的 SDK 封装
- ...

## 🛠 主题 2: Rust CLI 工具(3)
- ...

## 💎 本周小众之星
**zellij-contrib/zellij-ai**(⭐ 380) — 给终端多路复用器加 AI 助手,
和你上周 star 的 zellij 高度相关。

---
[💾 保存为 note] [🔄 重新生成] [⚙ 周报设置] [✕ 关闭]
```

### 5.3 关键交互

- **「💾 保存为 note」**: 整篇 markdown 存到 Starcat notes,tag 自动加 "周报" + "YYYY-WW"
- **「🔄 重新生成」**: 重跑 agent run(扣同样配额,新生成覆盖上次结果,**不**叠加)
- **「⚙ 周报设置」**: 跳转设置页(关闭 / 调整主题数 / 调整小众阈值)
- **已读标记**: 关闭周报窗口后,数字角标消失,本地记录 `lastReportReadAt`

---

## 六、数据闭环:新增 / 复用表

### 6.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `stars` 表(含 `created_at`) | 数据源 |
| `repo` 表 | repo 元信息 |
| `tag` + `repo_tag` | 主题聚类的标签体系参考 |
| `note` | 保存周报 |
| `AppSettings` | 周报偏好(开关 / 主题数) |
| GitHub token(`AuthSession`) | `get_repo_overview` 走认证 API |
| `EntitlementGate` + `quota` | Pro 拦截 |

### 6.2 新增 `weekly_report` 表(只存元信息,不存完整报告)

```sql
CREATE TABLE weekly_report (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    week_start INTEGER NOT NULL,        -- ISO 8601 周开始日期
    week_end INTEGER NOT NULL,
    new_star_count INTEGER NOT NULL,
    note_id INTEGER,                    -- 关联到 notes 表(保存过的话)
    created_at INTEGER NOT NULL,
    read_at INTEGER                     -- 用户读过的时刻(NULL = 未读)
);
CREATE INDEX idx_weekly_report_user ON weekly_report(user_id, week_start DESC);
```

**为什么不全量存报告**:
- 周报可能很大(2-5KB),本地存 100 份就 200-500KB(可接受,但收益不大)
- 报告用 LLM 重新生成成本 ≈ 0(已缓存 readme + LLM 廉价)
- 真要"存档"走 `note` 表(用户主动保存)

### 6.3 不引入新表的设计取舍

- **不存 cluster 主题标签**(LLM 每次聚类结果不稳定,存了也没法对比)
- **不存"小众之星"名单**(每周不同,存了反而要清理)

---

## 七、配置与触发

### 7.1 设置项(归到 `AppSettings.weeklyReport` 子结构)

```swift
struct WeeklyReportSettings: Codable {
    var enabled: Bool = true                  // 总开关
    var autoGenerateOnLaunch: Bool = true     // 打开 app 时自动生成(默认 7 天 + 1)
    var clusterCountTarget: Int = 4           // 主题聚类数(2-6)
    var hiddenGemMinStars: Int = 1000         // 小众阈值
    var hiddenGemMaxStars: Int = 5000         // 小众上限
    var language: ReportLanguage = .auto      // .auto / .zhHans / .en
    var proOnly: Bool = true                  // Pro only(默认)
}
```

### 7.2 触发逻辑(伪代码)

```swift
// 在 AppDelegate / @main 入口
func checkWeeklyReport() async {
    guard settings.weeklyReport.enabled, settings.weeklyReport.proOnly ? user.isPro : true else { return }
    let last = repo.getLatestWeeklyReport(for: user)
    let now = Date()
    if let last = last, now.timeIntervalSince(last.weekEnd) < 7 * 24 * 3600 { return }
    // 触发
    let report = try await orchestrator.run(goal: "生成本周 stars 周报", tools: [...])
    let saved = repo.saveWeeklyReport(userId: user.id, payload: report)
    // 通知 UI:角标 +1
    notificationCenter.post(.weeklyReportReady(saved.id))
}
```

### 7.3 后台推送(可选,不做 MVP)

如果未来要做 `NSBackgroundActivityScheduler` 周一早上 8 点跑:
- 见 `CLAUDE.md` "后台任务" 章节
- 需要 `Info.plist` 加 `NSBackgroundActivityScheduler` 权限说明
- App Sandbox 不影响(macOS 不像 iOS 那么严)
- 跑完通过 `UNUserNotificationCenter` 推本地通知

---

## 八、付费与配额

| 用户档 | 体验 |
|---|---|
| **Free** | 周报可看,但 cluster 数限制 2 个 + 隐藏"小众之星"区块;手动触发每周 1 次 |
| **Pro** | 完整 cluster 数 4-6 个 + 完整小众之星;可调整设置;每周可重新生成 3 次 |

- 单次 run 配额消耗: **1 quota**(聚合为一次 LLM 编排)
- 配额扣减: run 开始时预扣,失败回滚
- **Pro 拦截点**: `WeeklyReportSettings.proOnly` 检查 → `EntitlementGate.requirePro(.weeklyReport)`

---

## 九、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| `AgentTool` 协议 + 4 个 tool 实现 | 新增 | 中(与替代品推荐共用 50%) |
| `AgentOrchestrator` 通用编排循环 | 复用,无新增 | 0 |
| `weekly_report` 表 + DAO | 新增 | 小 |
| `WeeklyReportSettings` | 新增 | 小 |
| 周报 markdown 渲染 | 新增(可复用现有 markdown 组件) | 中 |
| 主窗口铃铛入口 + 角标 | 新增 | 小 |
| 周报窗口 UI(复用 chat 容器) | 扩展 | 小 |
| 「💾 / 🔄 / ⚙ / ✕」四个 action | 新增 | 中 |
| 触发逻辑(打开 app 检查) | 新增 | 小 |
| 单测 | 新增 | 中 |
| i18n 词条(`agent.weekly.*`) | 新增 | 小 |
| `docs/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: 小(因为与替代品推荐共用 50% 代码)。**与替代品推荐**串行做**比并行做省 30% 工作量**(因为 `AgentOrchestrator` / `AgentTool` / 4 个 tool 中有 2 个可共用)。

---

## 十、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| LLM 聚类质量不稳定(每次主题命名都不同) | 中 | `cluster_repos_by_topic` 强制 `@Generable` 结构化输出 + 主题命名带 "本周 主题 N" 兜底 |
| 周报中文表达僵硬 | 中 | system prompt 明确"用用户偏好的语言,简洁口语化,像朋友聊天" |
| 用户反感"AI 自动周报" | 中 | 默认开启可关闭;**绝不**做邮件推送(只在 app 内) |
| 0 个新 star 周也强行生成 | 低 | 检测 `newStarCount == 0` 直接跳过,显示 "本周没有新 star" |
| 后台推送打扰用户 | 中 | **MVP 不做后台推送**,只做"打开 app 检查 + 手动触发" |
| GitHub rate limit | 中 | 复用替代品推荐 §6.1 的限速策略 |
| 用户跨时区 / 跨周边界 | 低 | 用用户 locale 的周(Mon-Sun),存在 `AppSettings.locale` |
| 周报 LLM 调用挂起 | 中 | `maxSteps=8` + 每步超时 30s + run 总超时 120s |

---

## 十一、后续可拓展方向

1. **多周趋势对比**: "你这周比上周多关注了 AI Agent 30%"(基于历史周报)
2. **跨设备同步**: 通过 CloudKit 把周报同步到 iPhone / iPad(等 Starcat 上 iOS 后)
3. **主题订阅**: 让用户主动订阅主题("每周都给我推 AI Agent 的新星"),不只基于历史
4. **导出格式**: 支持导出为 Markdown / PDF / 邮件(给团队周会用)
5. **周报 widget**: macOS 桌面 widget,一眼看本周 stars 概览

---

## 十二、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿:基于 dong4j 讨论 + Starcat 现状评估 | Claude |
