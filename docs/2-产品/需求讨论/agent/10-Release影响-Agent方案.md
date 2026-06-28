# Release 影响 Agent 方案

> **文档定位**: 自动跟踪用户关注项目的 release,总结变更、判断是否值得升级。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板。
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`02-替代品推荐-Agent方案.md`](../agent/02-替代品推荐-Agent方案.md):共用 `AgentOrchestrator`
> - [`../概要设计.md`](../概要设计.md):Release 通知已有规划(P1)

---

## 一、用户故事

> 作为 Starcat 用户,我 star 了 swift,Swift 6.1 出了。agent 给我:
> 1. **一段话总结**: 6.1 主要是 X / Y / Z 改进
> 2. **是否含 breaking change**: 是(列出 3 条)+ 否(列出兼容改动)
> 3. **升级建议**:
>    - 个人小项目: ✅ 升(改动小,收益大)
>    - 团队项目: ⚠️ 慎(breaking change 较多,等 6.1.1)
>    - 旧 macOS 用户: ❌ 不升(需要 macOS 14+)
> 4. **我的项目是否受影响**: 自动检查我的本地代码是否用了 deprecated API

### 1.1 主动 + 被动两种触发

| 模式 | 触发 | 输出 |
|---|---|---|
| **主动**: 手动触发 | 在 repo detail 页面点"📰 查看近期 release 解读" | 弹窗:最近 N 个 release 的解读 |
| **被动**: 推送 | Starcat 后台定期(每日)扫用户 star 库,有新 release 时推送 | 通知中心一条 + 可选"自动跑解读" |

---

## 二、核心价值

> **"把 GitHub Release Notes 从'几百行 markdown'压缩成'30 秒可决策的判断'"**。

竞品对比:
- **GitHub Watch**: 通知太多,直接给你原文不解读
- **GitHub Releases Atom feed**: 同上
- **Dependabot**: 只针对依赖,不看用户主动 star 的
- **Starcat 本方案**: 用户主动 star 的 + AI 解读 + 升级建议

---

## 三、工具集

### 3.1 工具清单

```
Tool 1: fetch_recent_releases
  输入:  owner, repo, since(默认 30 天), maxCount(默认 5)
  输出:  Release[] (tag_name / name / published_at / body / html_url / prerelease)
  复用:  GitHub API /repos/{owner}/{repo}/releases

Tool 2: parse_release_notes
  输入:  releaseBody(String,可能几千行)
  输出:  结构化字段:
         { summary: String,
           breaking_changes: [String],
           new_features: [String],
           bug_fixes: [String],
           deprecations: [String],
           requires_action: Bool }
  内部:  调 LLM(必须,本地解析不可靠)

Tool 3: detect_migration_difficulty
  输入:  sourceVersion, targetVersion, repoLanguage
  输出:  "low" | "medium" | "high" + 理由
  内部:  调 LLM 基于 breaking_changes 数量 + 项目大小估算

Tool 4: check_user_local_impact
  输入:  userId(隐式), repoFullName, breakingChanges[]
  输出:  userProjectImpact: Bool + 受影响的文件数(估算)
  内部:  扫描用户本地 cached code(若有)或返回 "无本地代码可扫描"

Tool 5: get_release_frequency_history
  输入:  owner, repo, lastN(默认 12 个 release)
  输出:  ReleaseCadenceStats (平均间隔 / 趋势 / 上次 release 距今)
  复用:  GitHub API + 简单计算
```

### 3.2 工具 schema 关键约束

- `parse_release_notes` 强制 `@Generable` 输出 6 个固定字段,**绝不**让 LLM 自创字段
- `detect_migration_difficulty` 三档(避免 LLM 输出"中偏高"等模糊)
- `check_user_local_impact` 必须返回明确的"无本地代码"状态(不要 silent 空)
- 单 run 处理 release 数 ≤ 5(超过截断到最近 5,UI 提示)

---

## 四、Agent 编排循环

### 4.1 主动触发流程(用户点按钮)

```
[Step 1] system: "你是 Starcat Release 解读助手,基于 release notes 给升级建议"
[Step 2] user: "解读 swift 6.1 release"
[Step 3] tool_call: fetch_recent_releases("apple", "swift", since=60, max=5)
         → 5 个 release: 6.1 / 6.0.3 / 6.0.2 / 6.0.1 / 6.0
[Step 4] 对每个 release,tool_call: parse_release_notes(body)
         → 5 个结构化对象
[Step 5] tool_call: get_release_frequency_history("apple", "swift", lastN=12)
         → 平均 6 周一个 release,最近一个 8 周前
[Step 6] 对有 breaking change 的 release,tool_call: check_user_local_impact(...)
         → 用户无本地代码(空)
[Step 7] tool_call: detect_migration_difficulty(source=5.10, target=6.1, lang=Swift)
         → "medium" (3 个 breaking change)
[Step 8] LLM: 整合 5 个 release 解读 + 升级建议 + 频率分析
[Step 9] final_answer → UI 渲染
```

最大 8 步,实际 5-7 步(取决于 breaking change 数)。

### 4.2 被动推送流程

```
[每日定时] 扫用户 star 库(repo 数 N)
[对每个有新版 release 的 repo,批量并行跑主动流程]
[结果汇总到推送队列]
[通知中心统一展示: "X 个项目有新 release,可一键解读"]
```

**注意**: 被动推送**不**自动跑解读(避免 token 浪费),只通知;用户点通知才触发主动流程。

---

## 五、UI 落地

### 5.1 主动触发入口

**Repo detail 页面右侧栏加「📰 查看近期 release 解读」按钮**。

### 5.2 弹窗 UI

```
┌─ 📰 swift 近期 release 解读 ───────────────────────┐
│                                                     │
│  发布频率: 平均 6 周一个,最近 8 周前                │
│  ─────────────────────────────────────              │
│                                                     │
│  ## Swift 6.1(2026-06-12)                          │
│  一句话: 主要改进 X / Y / Z                          │
│                                                     │
│  ⚠️ Breaking Changes(3):                            │
│  • ...                                              │
│  • ...                                              │
│                                                     │
│  ✨ New Features(5):                                │
│  • ...                                              │
│                                                     │
│  🐛 Bug Fixes(12):                                  │
│  • ...                                              │
│                                                     │
│  升级建议: ⚠️ 中等(3 个 breaking)                  │
│  • 个人小项目: ✅ 升                                 │
│  • 团队项目: ⚠️ 等 6.1.1(预计 4-6 周)             │
│  • 你的本地项目: 📭 无本地代码可检查                 │
│                                                     │
│  [📖 查看原文] [📌 加入 watch list] [✓ 关闭]         │
│                                                     │
│  ## Swift 6.0.3(2026-05-20)                        │
│  一句话: ...                                        │
│  ...                                                │
└─────────────────────────────────────────────────────┘
```

### 5.3 被动推送(通知中心)

**主窗口右上角「🔔 通知」图标**(已有):
- 有新 release 未解读: 角标 "3"
- 点击: 跳到"通知中心"列表,显示 "swift 6.1 发布 / Alamofire 5.10 发布 / ..."
- 单击某条: 弹对应解读弹窗(走主动流程)
- 「全部标记已读」

### 5.4 关键交互

- **「📌 加入 watch list」**: 走 Starcat 已有 release watch 机制(若有;否则写 `repo_watch` 表)
- **「📖 查看原文」**: 系统浏览器打开 GitHub release 页
- **「🔄 重新解读」**: 重跑(同配额,新 LLM 输出)

### 5.5 错误处理

| 错误 | UI 表现 |
|---|---|
| 仓库没有 release | 提示"该仓库无 release 历史" |
| release body 为空 | 用 tag_name + 推送时间拼一句话"X.Y.Z 发布" |
| 全部 release 都是 prerelease | 提示"近期都是预发布版,正式版暂无" |
| LLM 解析失败 | 走原始 markdown 渲染(降级) |
| GitHub rate limit | 走现有 rate limit 处理,弹 toast |

---

## 六、数据闭环

### 6.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `stars` 表 | 被动推送的扫描源 |
| `auth_session` | GitHub 鉴权 |
| `note` | 保存解读报告 |
| `tag` + `repo_tag` | watch list tag |
| `EntitlementGate` + `quota` | Pro 拦截 |
| 通知中心(已有) | 被动推送 UI |

### 6.2 新增 `release_digest` 表(只存元信息)

```sql
CREATE TABLE release_digest (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    repo_id INTEGER NOT NULL,
    release_tag TEXT NOT NULL,
    release_published_at INTEGER NOT NULL,
    digest_json TEXT NOT NULL,         -- LLM 解析结果
    migration_difficulty TEXT,         -- 'low' | 'medium' | 'high'
    read_at INTEGER,                   -- NULL = 未读
    dismissed_at INTEGER,              -- 用户主动 dismiss
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_release_digest_user ON release_digest(user_id, read_at);
CREATE UNIQUE INDEX idx_release_digest_unique ON release_digest(user_id, repo_id, release_tag);
```

**为什么需要这张表**:
- 通知中心"未读 / 已读 / 已 dismiss"状态
- 避免对同一 release 重复推送
- 后续做"release 历史时间线"(`note` 之外的轻量元数据)
- 不存 release body 原文(太大,GitHub URL 就够了)

### 6.3 不引入新表的设计取舍

- 不存"用户偏好(只想要 breaking change 通知)"——放 `AppSettings`
- 不存"用户解读历史"——`release_digest` 已够

---

## 七、付费与配额

| 用户档 | 体验 |
|---|---|
| **Free** | 主动触发每月 20 次;**无**被动推送;只看 top 3 release |
| **Pro** | 不限主动;每日被动推送(最多 5 条/天);看全部 release;可设置"只看 major / minor / patch" |

- 单次 run 配额: **1 quota/release**(聚合为 1 run 实际扣 1 quota,UI 显示"5 个 release"以体现价值)
- 配额回滚:release 抓取失败回滚,LLM 失败不回滚

---

## 八、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| 5 个 Tool 实现 | 新增 | 中 |
| `release_digest` 表 + DAO | 新增 | 小 |
| 「📰 查看近期 release」按钮 | 新增 | 极小 |
| 解读弹窗 UI | 新增 | 中 |
| 通知中心集成 | 扩展已有 | 小 |
| 每日定时任务(被动推送) | 新增(走 NSBackgroundActivityScheduler 已有) | 小 |
| 用户偏好设置(只看 major 等) | 新增 | 小 |
| 单测(LLM 解析 / breaking 检测) | 新增 | 中 |
| i18n 词条(`agent.releasedigest.*`) | 新增 | 小 |
| `docs/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: 中等。**最大难点是 `parse_release_notes` 的 prompt**,不同项目的 release notes 风格差异巨大(有的用 conventional commits,有的散文),需要 30+ 真实样本迭代。

---

## 九、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| 被动推送刷屏(用户 star 1000 个,每天 10 个 release) | **高** | 每日上限 5 条;聚合(同 repo 多次 release 合并);"只看 major"开关 |
| LLM 把 minor change 误判为 breaking | 中 | prompt 强调"breaking 必须有明确 removed/changed API 证据";有疑问归"deprecation" |
| LLM 把 breaking 漏掉 | 中 | 同时跑简单关键字扫描("BREAKING" / "removed" / "migration"),双保险 |
| 误读 prerelease(把 beta 解读成 stable) | 中 | 强制显示 "⚠️ 这是预发布版";不影响升级建议 |
| GitHub rate limit(star 1000 个 repo) | 中 | 走 AuthSession 复用用户 token;每日扫描限 5 个 repo + 队列化 |
| 用户本地代码扫描涉及隐私 | **高** | v1 不做"扫描本地代码",`check_user_local_impact` 只返回"无本地代码";v2 才做显式 opt-in 扫描 |
| Release notes 是图片 / 视频(LLM 读不到) | 中 | 提示"该 release 含图片,部分内容无法解读";给原文链接 |

---

## 十、后续可拓展方向

1. **依赖链追踪**: 用户的项目 A 依赖 B,B 出了 breaking → 推送"你的 A 可能受影响"
2. **跨项目 release 对比**: 同期 N 个同领域项目的 release,看趋势
3. **自动升级 PR**: 检测到用户本地项目有新版可用,自动开 PR(需用户授权 + GitHub App 权限)
4. **release notes 翻译**: 用户偏好语言不是英文时,自动翻译 release notes
5. **"我应该升吗"问答**: 用户主动问"我现在用 5.10,要升 6.1 吗?",基于用户项目实际场景回答
6. **release 时间线图表**: 某 repo 的 release 频率 / 大小趋势图

---

## 十一、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿 | Claude |
