# 项目采用计划 Agent 方案

> **文档定位**: 用户对某个 repo 生成"接入步骤 / PoC checklist / 风险点"——回答"我能不能 / 该不该用这个库"。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板。
> **关联文档**:
> - [`12-技术栈迁移-Agent方案.md`](12-技术栈迁移-Agent方案.md):近亲——"A→B 怎么走" vs "该不该用 B"
> - [`11-安全与License风险-Agent方案.md`](11-安全与License风险-Agent方案.md):本方案 7 维风险评估的"采纳侧"
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)

---

## 一、用户故事

> 作为 Starcat 用户,我在浏览一个候选 repo(比如某个 Rust HTTP 库),想知道"我该不该用"。agent 给我一份**采用决策书**:
> 1. **TL;DR**: 适合什么场景 / 不适合什么场景(3 句话)
> 2. **快速试一下**: 5 步,30 分钟内能跑通 hello world
> 3. **PoC 清单**: 7 项(集成 / 性能 / 错误处理 / 文档 / 社区响应 / 长期维护)
> 4. **风险点**: 5 个,按严重程度排序
> 5. **成本估算**: 学习时间 / 集成工作量 / 长期维护成本
> 6. **团队适配**: 团队是否需要先培训(看团队现有技术栈)
> 7. **替代选项**: 3 个更轻 / 更主流 / 更成熟的对照
> 8. **决策建议**: ✅ 用 / ⚠️ 谨慎 / ❌ 不用 + 理由

### 1.1 关键差异(与 11 安全风险、12 迁移)

| 维度 | 11 风险评估 | 12 迁移规划 | **13 采用计划(本方案)** |
|---|---|---|---|
| 输入 | 已有 repo 的健康度 | A→B 的具体迁移 | "我要不要用 X" |
| 输出 | 7 维风险评分 | 7 section 迁移指南 | 8 section 决策书 |
| 决策 | "用 / 不用 X" | "怎么从 A 迁到 B" | "评估 X 适不适合我" |
| 维度 | 7 维客观(license/活跃度/...) | 跨库对照 | **主观 + 客观**(团队/场景匹配) |
| 视角 | repo 自身 | repo A vs B | **用户项目 vs repo** |

---

## 二、核心价值

> **"star 之前,先做一次 5 分钟评估"——把'装上试试再说'变成'先决策再装'"**。

竞品分析:
- **GitHub README + Examples**: 给"怎么用",不给"该不该用"
- **Reddit/HN 讨论**: 主观,碎片
- **Starcat 本方案**: **结构化决策书**,基于用户项目场景

---

## 三、工具集

### 3.1 工具清单

```
Tool 1: get_candidate_repo_context
  输入:  owner, repo
  输出:  description / readme 前 500 tokens / 主要 API / 主要 use case
  复用:  Starcat 已有 RepoAIContextProvider

Tool 2: analyze_dependencies
  输入:  owner, repo
  输出:  { runtime_deps: [Name], dev_deps: [Name], transitive_size: Int,
           platform_restrictions: [String] }
  复用:  GitHub Dependency graph API(若有)+ 静态分析 README/package.json

Tool 3: extract_quickstart_steps
  输入:  owner, repo
  输出:  QuickStartStep[] (order / command / expected_output / estimated_minutes)
  内部:  调 LLM 解析 README 中的 "Quick Start" / "Getting Started" 章节

Tool 4: get_user_project_context  (需用户授权)
  输入:  userId(隐式)
  输出:  { language: String, framework: String, current_libs: [String],
           team_size: Int, has_tests: Bool, ci_cd: String }
  来源:  用户的 stars / notes / 偏好设置(推断)+ 用户显式填表

Tool 5: assess_compatibility
  输入:  candidateRepo, userProjectContext
  输出:  { language_match: Bool, framework_conflict: [String],
           license_compatible: Bool, platform_supported: Bool,
           learning_curve: 'low' | 'medium' | 'high' }
  内部:  调 LLM 综合判断

Tool 6: generate_poc_checklist
  输入:  candidateRepo, userProjectContext, compatibility
  输出:  PocItem[] (item / why_test / how_to_test / pass_criteria)
  覆盖: 集成 / 性能 / 错误处理 / 文档 / 社区 / 长期维护

Tool 7: estimate_adoption_cost
  输入:  candidateRepo, userProjectContext
  输出:  { learning_hours: Double, integration_days: Double,
           long_term_maintenance_hours_per_month: Double,
           team_training_hours: Double }

Tool 8: synthesize_adoption_report
  输入:  上述所有 tool result
  输出:  8 section markdown 决策书
  内部:  调 LLM 整合,@Generable 强制结构
```

### 3.2 工具 schema 关键约束

- `extract_quickstart_steps` 必须 3-7 步(太多说明文档差,太少说明不成熟)
- `assess_compatibility` 4 个布尔项**必须**全有,允许 false 但必须有结论
- `generate_poc_checklist` 6-10 项,覆盖 6 个维度
- `estimate_adoption_cost` 4 个数字**必须**都给(允许 0)
- 单 run = 1 个候选 repo

---

## 四、Agent 编排循环

```
[Step 1] system: "你是 Starcat 采纳评估助手,基于候选 repo + 用户项目,生成 8 section 决策书"
[Step 2] user: "评估我该不该用 reqwest 替代我现在的 Rust HTTP 库"
[Step 3] tool_call: get_candidate_repo_context("seanmonstar", "reqwest")
[Step 4] tool_call: analyze_dependencies("seanmonstar", "reqwest")
[Step 5] tool_call: extract_quickstart_steps("seanmonstar", "reqwest")
[Step 6] tool_call: get_user_project_context(userId)
[Step 7] tool_call: assess_compatibility(reqwest, userProjectContext)
[Step 8] tool_call: generate_poc_checklist(reqwest, userProjectContext, compatibility)
[Step 9] tool_call: estimate_adoption_cost(reqwest, userProjectContext)
[Step 10] tool_call: synthesize_adoption_report(...)
[Step 11] final_answer → UI 渲染
```

最大 10 步,实际 7-8 步。

---

## 五、UI 落地

### 5.1 入口

**Repo detail 页面右侧栏加「📋 生成采用计划」按钮**(在"🛡️ 风险评估" / "🔍 找同类项目" 旁)。

### 5.2 报告 UI(8 section)

```
┌─ 📋 采用决策书: reqwest ───────────────────────────┐
│                                                     │
│  TL;DR: Rust 生态最成熟的 HTTP 客户端。适合 Rust   │
│  服务端 / CLI 工具,不适合嵌入式 / 极致轻量场景。   │
│                                                     │
│  ── 1. 快速试一下(5 步,30 分钟) ──                │
│  1. `cargo new test-reqwest` (1 min)                │
│  2. `cargo add reqwest` (1 min)                    │
│  3. 写 1 个 GET 请求(5 min)                       │
│  4. 跑测试(2 min)                                  │
│  5. 尝试 JSON 反序列化(20 min)                     │
│                                                     │
│  ── 2. PoC 清单(7 项) ──                          │
│  ☐ 集成: 最小可用集成跑通                          │
│  ☐ 性能: 与现有方案基准对比                         │
│  ☐ 错误处理: 自定义 error type                      │
│  ☐ 文档: 团队 1 人独立完成 hello world              │
│  ☐ 社区响应: GitHub issue 平均响应 < 3 天           │
│  ☐ 长期维护: 过去 6 个月有 release                  │
│  ☐ 团队培训: 团队 Rust 熟练度足够                   │
│                                                     │
│  ── 3. 风险点(5 个) ──                            │
│  1. (高) tokio 强依赖,引入后整个项目异步运行时被绑  │
│  2. (中) 部分高级特性在稳定版不可用                  │
│  3. ...                                             │
│                                                     │
│  ── 4. 成本估算 ──                                  │
│  - 学习时间: 4-6 小时                              │
│  - 集成工作量: 1-2 人天                             │
│  - 长期维护: 每月 0.5-1 小时                        │
│  - 团队培训: 0 小时(团队已熟 Rust)                  │
│                                                     │
│  ── 5. 团队适配 ──                                  │
│  ✅ 团队 Rust 熟练度高                              │
│  ✅ 已有 tokio 经验                                 │
│  ⚠️ 1 位初级 Rust 开发者需 2 天学习                 │
│                                                     │
│  ── 6. 替代选项 ──                                  │
│ - ureq(更轻,但功能少)                              │
│ - hyper(更底层,灵活性高)                           │
│ - curl crate(走 libcurl)                            │
│                                                     │
│  ── 7. 决策建议 ──                                  │
│  ✅ 建议采用(理由: 你的项目是 Rust + 团队熟练)    │
│                                                     │
│  [💾 保存为 note]  [📤 分享给团队]  [🔄 重新评估]  │
│  [✕ 关闭]                                           │
└─────────────────────────────────────────────────────┘
```

### 5.3 关键交互

- **「💾 保存为 note」**: 整篇决策书存为 note,tag "adoption"
- **「📤 分享给团队」**: 生成 URL(本地链接,同 12 迁移)
- **「🔄 重新评估」**: 重跑(同配额)
- **「📋 复制 PoC 清单」**: 7 项复制为 markdown checklist
- **「⭐ 评估后 star」**: 决策建议是"用"时,直接 star 按钮

### 5.4 错误处理

| 错误 | UI 表现 |
|---|---|
| `get_user_project_context` 无数据(用户未授权 / 未填) | 弹窗让用户填 5 项基本信息(language / framework / team_size / current_libs / has_tests) |
| 候选 repo 无 quickstart | section 1 改"暂无 quickstart,需自行摸索,以下是 README 摘要" |
| 兼容性判定失败(LLM 不知道某个 lib) | 4 个布尔项里"未知"标 ❓,UI 提示"该评估不完整" |
| 估算数字跨度大 | 强制给"乐观 / 典型 / 悲观"三档,不是单点 |

---

## 六、数据闭环

### 6.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `auth_session` | GitHub 鉴权 |
| `RepoAIContextProvider` | 拉 lib context |
| `stars` 表 | 推断用户项目技术栈 |
| `note` 表 | 保存决策书 |
| `tag` + `repo_tag` | adoption tag |
| `EntitlementGate` + `quota` | Pro 拦截 |
| `AIClient` | 调 LLM |
| `AppSettings` | 保存用户填的项目基本信息(避免每次重填) |

### 6.2 新增 `user_project_profile` 表(用户项目信息)

```sql
CREATE TABLE user_project_profile (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    profile_name TEXT NOT NULL,        -- 'personal-blog' | 'work-saas' | 'side-project-x'
    language TEXT,
    framework TEXT,
    team_size INTEGER,
    current_libs TEXT,                 -- JSON array
    has_tests INTEGER,                 -- 0 / 1
    ci_cd TEXT,
    is_default INTEGER,                -- 0 / 1,默认 profile 用于"未指定时"
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX idx_user_project_profile_user ON user_project_profile(user_id);
```

**为什么需要这张表**:
- 用户可能同时有"个人项目 / 工作项目 / side project",profile 不同评估也不同
- 避免每次评估都重填
- 不存敏感信息(项目名 / 代码)

### 6.3 不引入新表的设计取舍

- 不存"用户每次评估历史"——`note` 表 + repo 关联已够
- 不存"决策建议"——LLM 重新生成成本 < 存储成本

---

## 七、付费与配额

| 用户档 | 体验 |
|---|---|
| **Free** | 每月 5 次采用评估;只能用默认 profile(无自定义);保存 note 单次 |
| **Pro** | 不限次数;多个 profile(个人 / 工作 / side);批量评估(N 个 repo);导出团队分享链接 |

- 单次 run 配额: **2 quota**(多 tool 聚合)
- 配额回滚:1-2 tool 失败不回滚,≥ 4 tool 失败回滚

---

## 八、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| 8 个 Tool 实现 | 新增 | 中(与 12 迁移共用 30%) |
| `user_project_profile` 表 + DAO | 新增 | 小 |
| profile 编辑 UI | 新增 | 中 |
| 「📋 生成采用计划」按钮 | 新增 | 极小 |
| 8 section 决策书 UI | 新增 | 中 |
| 团队分享链接(复用 12) | 0(共用) | 0 |
| 单测(compatibility / 估算 / 决策) | 新增 | 中 |
| i18n 词条(`agent.adoption.*`) | 新增 | 小 |
| `docs/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: 中等。**与 12 迁移规划串行做可省 30%** (共用 estimate_cost / compatibility / 团队分享 3 个 tool)。

---

## 九、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| LLM 决策建议偏主观(总说"用") | **高** | 强制 3 档(✅/⚠️/❌),且必须有理由;不一致时人工抽检 |
| 兼容性判定不准(LLM 不知道某 lib) | 中 | 4 个布尔项允许 ❓(未知),UI 强提示"该评估不完整" |
| 用户项目信息过时(用户去年填的 profile) | 中 | 6 个月未更新的 profile 评估时弹 toast 提醒刷新 |
| 决策书过短(LLM 偷懒) | 中 | 强制每个 section 至少 N 字;输出长度不达标 reject |
| 决策书过长(用户读不完) | 中 | section 1-2 强制精简;section 3-7 可折叠 |
| 团队分享链接外泄 | 低 | 同 12,默认同 LAN |
| 用户把"AI 决策书"当真 | 中 | 固定底部:"⚠️ 本评估基于公开数据 + 你的项目 profile,实际决定前请小范围 PoC" |

---

## 十、后续可拓展方向

1. **批量评估**: 选中 N 个候选 repo,一次性出 N 份决策书(企业用户场景)
2. **历史决策回看**: "我之前评估过 X,后来我用了 / 没用,实际感受如何"——反馈学习
3. **"团队 5 人 1 票"投票**: 决策书末尾加投票链接,5 人都表态后才决定
4. **集成 Code Review**: 评估后,把候选 repo 加入 PR 检查清单(用 Snyk 等)
5. **跨决策书聚合**: 用户的"采用计划"清单 → 团队技术雷达图
6. **风险预测**: "采用 6 个月后,可能遇到 X 问题"——基于同类 repo 经验
7. **AI 反向推荐**: "你不该用 X,应该用 Y"——基于你的 stars 库 + 团队 profile

---

## 十一、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿 | Claude |
