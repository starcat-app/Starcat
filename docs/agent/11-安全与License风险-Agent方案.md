# 安全与 License 风险 Agent 方案

> **文档定位**: 检查 repo 的 license / archived / security advisory / 维护停滞等风险信号,给出风险评分。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板。
> **关联文档**:
> - Starcat 已有 `RepoHealthSheet`(部分能力,见 `Starcat/Features/Health/`)
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`../CLAUDE.md`](../CLAUDE.md):AI 保守策略(风险结论预览 → 确认 → 写入)

---

## 一、用户故事

### 1.1 主动触发(用户导入 / 浏览时)

> 我新 star 了一个 repo(比如某个 Go 库),agent 立刻给我一张**风险卡片**:
> - 🟢 License: MIT(宽松)
> - 🟢 维护: 4 周内有 commit
> - 🟡 警告: 1 个未修 security advisory(影响 < 1% 用户)
> - 🟢 文档: 有 README + CONTRIBUTING
> - 🟢 社区: > 100 contributors
> - **综合风险**: 低(可放心 star)

### 1.2 被动巡检(后台定期)

> 我 star 库里有 300 个 repo,后台每周扫一次,把"风险等级升高"的 repo 推给我:
> - "X 仓库 6 个月没更新了,可能已停滞,建议关注"
> - "Y 仓库新出了 critical security advisory,建议升级"

---

## 二、核心价值

> **"让用户 star 前就看清风险,避免事后踩坑"**——大多数 star 决策是冲动的,这个 agent 充当"刹车"。

竞品对比:
- **GitHub Security tab**: 用户必须主动去看
- **Snyk / Dependabot**: 只针对项目**自身依赖**,不针对用户 star 行为
- **Starcat 本方案**: 基于**用户 star 库**的风险盘点,主动推送

---

## 三、风险维度(7 项)

| # | 维度 | 数据源 | 风险等级 |
|---|---|---|---|
| 1 | **License 类型** | GitHub API `license` 字段 + SPDX 解析 | 🟢 MIT/Apache/BSD / 🟡 LGPL/MPL / 🔴 GPL/AGPL/SSPL/无 |
| 2 | **archived 状态** | GitHub API `archived: true` | 🟢 false / 🔴 true(必须强烈提示) |
| 3 | **维护活跃度** | 最近 commit / release 时间 | 🟢 1 月内 / 🟡 3-12 月 / 🔴 > 12 月 |
| 4 | **security advisories** | GitHub Security Advisories API | 🟢 0 / 🟡 1-2 个低/中 / 🔴 1+ 个 high/critical |
| 5 | **dependencies 健康度** | GitHub API dependencies + Dependabot 状态 | 🟢 无依赖或全最新 / 🟡 部分过期 / 🔴 大量过期 |
| 6 | **contributors 集中度** | GitHub API contributors + 提交占比 | 🟢 top1 < 30% / 🟡 top1 30-60% / 🔴 top1 > 60%(bus factor 低) |
| 7 | **社区健康度** | issue 响应中位数 + PR 合并率 | 🟢 < 7 天 / 🟡 7-30 天 / 🔴 > 30 天 |

**综合风险** = 7 维加权(各 1/7 权重,任一 🔴 直接升 🔴)

---

## 四、工具集

### 4.1 工具清单

```
Tool 1: get_license_info
  输入:  owner, repo
  输出:  { spdx_id: String, name: String, permissions: [String], conditions: [String],
           limitations: [String], is_copyleft: Bool, is_osl_approved: Bool, url: String }
  复用:  GitHub API /repos/{owner}/{repo}/license + SPDX 解析

Tool 2: check_archived_status
  输入:  owner, repo
  输出:  { archived: Bool, archived_at: Date?, reason: String?(GitHub 给的原因) }
  复用:  GitHub API

Tool 3: check_maintenance_activity
  输入:  owner, repo
  输出:  { last_commit_at: Date, last_release_at: Date?,
           commit_count_30d: Int, commit_count_90d: Int,
           release_count_12m: Int, contributor_count_30d: Int }
  复用:  GitHub API

Tool 4: fetch_security_advisories
  输入:  owner, repo
  输出:  Advisory[] (ghsa_id, severity, summary, published_at, patched_versions)
  复用:  GitHub Security Advisories API

Tool 5: check_dependencies_health
  输入:  owner, repo
  输出:  { total_deps: Int, outdated: Int, deprecated: Int, has_dependabot: Bool }
  复用:  GitHub Dependency graph API(需 repo 启用)

Tool 6: check_bus_factor
  输入:  owner, repo
  输出:  { top1_contributor_pct: Double, top3_pct: Double, total_contributors: Int }
  复用:  GitHub Contributors API + 简单计算

Tool 7: check_community_health
  输入:  owner, repo
  输出:  { issue_response_median_days: Double, pr_merge_rate_30d: Double,
           open_issues: Int, open_prs: Int }
  复用:  GitHub Issues API

Tool 8: synthesize_risk_report
  输入:  上述 7 个 tool 的 result
  输出:  7 维评分 + 综合等级 + 自然语言解释
  内部:  调 LLM 综合,@Generable 强制结构
```

### 4.2 工具 schema 关键约束

- `get_license_info` 必须解析 SPDX,**不**用 GitHub 自定义 key
- `check_archived_status` 若 archived,**强制**返回 `reason`(用户决策需要)
- `fetch_security_advisories` severity 强制四档枚举(`low`/`medium`/`high`/`critical`)
- `synthesize_risk_report` 7 维评分独立,不互相覆盖
- 单 run 抓取 7 个 tool,**必须**并发(否则体验差)

---

## 五、Agent 编排循环

### 5.1 主动触发(单 repo)

```
[Step 1] system: "你是 Starcat 风险评估助手,7 维评估 repo 风险"
[Step 2] user: "评估 gofiber/fiber 的风险"
[Step 3-9] 并发 7 个 tool: license / archived / maintenance / advisories / 
                            deps_health / bus_factor / community_health
[Step 10] tool_call: synthesize_risk_report(7 个 result)
[Step 11] final_answer → UI 渲染风险卡片
```

最大 6 步(并发 7 tool + 综合),实际 2 步。

### 5.2 被动巡检(全 stars 库)

```
[每周定时] 扫用户 stars 库
[对每个 repo,跑主动流程]
[结果与上次对比: 风险等级变化 / 新增 advisory / 变 archived / ...]
[过滤出"变化超过阈值"的 → 推送]
```

**注意**: 被动巡检**不**每天跑(7 tool × N repo 太重),**每周一次**。且只推"变化显著"的,不刷屏。

---

## 六、UI 落地

### 6.1 主动触发入口

- **Repo detail 页面**: 加「🛡️ 风险评估」按钮(在 "🔍 找同类项目" 旁边)
- **新 star 导入时**: 自动跑一次(后台),完成后显示小红点提示"已评估,查看"

### 6.2 风险卡片 UI(嵌入 Repo detail 右侧栏)

```
┌─ 🛡️ 风险评估: gofiber/fiber ───────────────────────┐
│                                                     │
│  综合风险: 🟢 低(可放心使用)                       │
│  评估时间: 2026-06-27 14:32                         │
│                                                     │
│  ─────────────────────────────────────              │
│  1. License: 🟢 MIT(宽松)                          │
│  2. Archived: 🟢 活跃                                │
│  3. 维护: 🟢 3 天前 commit                          │
│  4. 安全公告: 🟢 0                                   │
│  5. 依赖: 🟡 2/47 过期                              │
│  6. Bus factor: 🟢 top1 占 12%                      │
│  7. 社区: 🟢 issue 响应中位数 1 天                   │
│                                                     │
│  建议: 无需特别关注,可放心使用。                    │
│                                                     │
│  [📖 查看原始数据]  [🔄 重新评估]  [✕ 关闭]        │
└─────────────────────────────────────────────────────┘
```

### 6.3 被动推送(通知中心)

**主窗口「🔔 通知」图标**:
- 角标: 新增风险条数
- 列表项格式: "gofiber/fiber 风险等级变化: 🟢 → 🟡(1 个新 advisory)"

### 6.4 关键交互

- **「📖 查看原始数据」**: 展开 7 维原始 JSON(给开发者看)
- **「🔄 重新评估」**: 重跑(同配额)
- **「🔕 忽略此仓库风险」**: 把该 repo 加入 `risk_muted` 列表(用户主动静默)
- **「📌 关注」**: 当风险等级变化时,优先推送

### 6.5 错误处理

| 错误 | UI 表现 |
|---|---|
| 仓库无 license 字段 | 🟡 "未声明 license,默认视为保留所有权利(不可用)" |
| 安全公告 API 无权限(私有库) | 🟡 "无法检查 security advisory"(降级) |
| 依赖图未启用 | 🟡 "依赖图未启用,无法评估依赖" |
| 7 个 tool 中 1-2 个失败 | 仍出报告,失败维度标 "无法评估",综合等级按已知维度算 |
| 7 个 tool 中 ≥ 3 个失败 | 直接显示"评估失败,稍后再试" |

---

## 七、数据闭环

### 7.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `stars` 表 | 巡检扫描源 |
| `repo_health` 表(若有) | 维护活跃度复用 |
| `auth_session` | GitHub 鉴权 |
| `note` | 保存风险报告 |
| `EntitlementGate` + `quota` | 配额控制 |
| 通知中心(已有) | 被动推送 UI |

### 7.2 新增 `risk_assessment` 表(全量历史)

```sql
CREATE TABLE risk_assessment (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    repo_id INTEGER NOT NULL,
    assessed_at INTEGER NOT NULL,
    overall_risk TEXT NOT NULL,         -- 'low' | 'medium' | 'high' | 'critical'
    dimensions_json TEXT NOT NULL,      -- 7 维评分
    advisory_count INTEGER NOT NULL,
    read_at INTEGER,
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_risk_assessment_user_repo ON risk_assessment(user_id, repo_id, assessed_at DESC);
```

**为什么需要这张表**:
- 趋势分析("这个 repo 风险是慢慢升高的")
- 推送去重(同一 repo 同一等级不重复推)
- 用户决策证据(可以回看"半年前我看到的是 🟢,现在 🟡,为什么")

### 7.3 新增 `risk_muted` 表(用户主动静默)

```sql
CREATE TABLE risk_muted (
    user_id INTEGER NOT NULL,
    repo_id INTEGER NOT NULL,
    muted_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, repo_id)
);
```

---

## 八、付费与配额

| 用户档 | 体验 |
|---|---|
| **Free** | 主动触发每月 30 次(单 repo);**无**被动巡检;只看综合等级,7 维详情灰 |
| **Pro** | 不限主动;**每周**被动巡检;7 维详情可看;趋势图;导出风险报告 |

- 单次 run 配额: **1 quota / 7 tool 并发**(实际算 1 run)
- 配额回滚:≥ 3 tool 失败回滚
- 被动巡检: Pro only,每周固定消耗 1 quota(全 stars 库扫一次)

---

## 九、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| 8 个 Tool 实现(含 SPDX 解析) | 新增 | 中(SPDX 解析可能用现成 SPM) |
| `risk_assessment` 表 + DAO | 新增 | 小 |
| `risk_muted` 表 + DAO | 新增 | 极小 |
| 风险卡片 UI | 新增 | 中 |
| 「🛡️ 风险评估」按钮 | 新增 | 极小 |
| 通知中心集成 | 扩展 | 小 |
| 每周定时任务(被动巡检) | 新增 | 小 |
| 趋势图(Pro) | 新增 | 中 |
| 单测(7 维 + 综合) | 新增 | 中 |
| i18n 词条(`agent.risk.*`) | 新增 | 小 |
| `docs/工程进度/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: 中等。最大难点是 SPDX 解析 + 7 维加权算法。

---

## 十、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| License 误判(GPL 但项目实际是 "GPL + 商业例外") | **高** | UI 显式提示"以 LICENSE 文件原文为准,本评估仅供参考";不替代法务 |
| Security advisory API 权限(部分私有库) | 中 | 走 AuthSession 鉴权;失败时降级 |
| Bus factor 误判(大公司 monorepo 算 top1 是公司账号) | 中 | 排除"bot"和"公司主账号"再算 |
| 巡检刷屏(每周 300 个 repo 出 50 条变化) | **高** | 聚合(同 risk_level + 同 repo_type 合并);每日上限 3 条 |
| 风险评分变化太快(star 1 天 5 次变化) | 低 | 缓存 7 天,7 天内不重算 |
| 7 tool 并发触发 GitHub rate limit | 中 | 走 Starcat 已有 rate limit 处理(批量 + 限速) |
| 用户看不懂"SPDX / bus factor" | 中 | UI 强 tooltip;科普向解释(可点开) |

---

## 十一、后续可拓展方向

1. **风险等级随时间趋势图**(Pro)——展示某 repo 风险随时间变化
2. **批量评估**: 选中 N 个 repo,批量跑(企业用户场景)
3. **导出风险报告**: 生成 PDF / 表格,给团队决策用
4. **集成 SBOM**: 把"用户 star 库的 SBOM"导出,帮企业过审计
5. **自定义风险维度**: 用户加自己的检查项(比如"必须用某 CI 系统")
6. **跨 stars 库风险总览**: "你 star 的 300 个 repo 中,12 个 🟡, 3 个 🔴"
7. **"该 repo 适合我吗"反向**: 不仅风险,还评估"匹配度"(基于用户偏好)

---

## 十二、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿 | Claude |
