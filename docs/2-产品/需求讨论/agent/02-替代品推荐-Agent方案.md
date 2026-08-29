# 替代品推荐 Agent 方案(数据闭环最强)

> **文档定位**: "替代品推荐 agent"的详细方案。d# 在 Starcat 中做"从用户现有 stars 出发,智能推荐相似但更现代 / 更活跃 / 评价更好的替代项目"。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板立项。
> **推荐度**: 🥇(见 [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md))
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`../AI代理API设计.md`](../AI代理API设计.md):现有 AI Proxy 协议
> - [`../功能清单.md`](../功能清单.md):P0/P1/P2 优先级
> - [`../../../../AGENTS.md`](../../../../AGENTS.md):AI 保守策略铁律

---

## 一、用户故事

### 1.1 主流程

> 作为 Starcat 用户,我在浏览我 star 过的一个仓库时(例如 5 年没更新的 vim 配置),希望看到一个"**替代品**"面板,告诉我:
> - 有 3 个更现代的替代(neovim / helix / lapcat)
> - 它们的 star 数、维护活跃度、目标用户差异
> - 我可以一键 star 它们(走 GitHub API)
> - 我可以一键把它们加入我的"待考察" tag

### 1.2 反向触发(主动发现)

> 作为 Starcat 用户,我想让 agent 每周自动扫一遍我的 stars,找出"**维护停滞 / 已归档 / 有更好替代**"的仓库,生成一份清单推给我。

---

## 二、核心价值 & 差异化

| 维度 | Starcat 现有能力 | 竞品(GitHub Trending / Explore) | 替代品推荐 Agent |
|---|---|---|---|
| 推荐来源 | 无 | 全网热门 | **基于用户个人 stars 库** |
| 相似度计算 | 无 | 标签 / 主题 | 语义 + tag + 语言 + 描述 embedding |
| 维护活跃度 | `RepoHealthSheet` 部分 | 无 | **主动扫描** commits / releases |
| 用户干预 | 无 | 无 | **接受 / 拒绝 / 收藏** 三态 |
| 增量学习 | 无 | 无 | **基于用户反馈**(接受过的替代不重复推) |

> **核心差异化**: "基于你 star 历史的**个性化**替代推荐",GitHub Trending 给不了。

---

## 三、工具集设计

### 3.1 工具清单

```
Tool 1: get_starred_repo_context
  输入:  owner, repo
  输出:  description / stars / language / topics / last_push_at /
         readme 前 500 tokens / 用户私有 note 前 200 tokens
  复用:  Starcat 已有 RepoAIContextProvider

Tool 2: search_github_alternatives
  输入:  query, language?, minStars?, pushedAfter?(默认 12 个月内)
  输出:  Top 10 候选 repo(只取 description / stars / topics / last_push / license)
  复用:  Starcat 已有 GitHub Search API(走 AuthSession)

Tool 3: compare_repos
  输入:  sourceRepo, candidateRepos[](2-5 个)
  输出:  2-5 个 repo 的**结构化对比表**:
         - 定位差异(目标用户 / 解决的核心问题)
         - 活跃度(最近 commit / release 间隔)
         - 生态(issue 响应中位数 / contributors 数)
         - 上手成本(配置复杂度 / 文档质量)
  内部:  调用 LLM 做归纳,**不**返回原文,避免吃 token

Tool 4: get_user_recent_feedback
  输入:  userId(隐式 = 当前登录用户)
  输出:  历史上接受 / 拒绝过的推荐(避免重复)
  复用:  Starcat 已有"agent 反馈表"(新,见 §6.3)
```

### 3.2 工具 schema 关键约束

- **`search_github_alternatives` 必须支持 `pushedAfter`**: 没有这个过滤,会推荐一堆已 archived 的"老牌",违背"替代"语义
- **`compare_repos` 候选数必须 2-5 个**: 少于 2 没意义,多于 5 LLM 输出会冗长
- **所有工具失败必须返回结构化错误**(不是抛异常),让 LLM 决定是否换路径

---

## 四、Agent 编排循环

### 4.1 单仓库触发流程(主流程)

```
[Step 1] system: "你是替代品推荐助手,基于用户 stars 库找更现代的替代"
[Step 2] user: "推荐 vim 配置的替代品"   (or 自动从 star detail 触发)
[Step 3] tool_call: get_starred_repo_context("dong4j", "vim-config")
         → description / language / topics / last push 2 年前
[Step 4] tool_call: search_github_alternatives(
             query="vim configuration modern", language="Lua",
             minStars=500, pushedAfter="2024-06-01")
         → 10 个候选,过滤后剩 4 个活跃的
[Step 5] tool_call: get_user_recent_feedback()
         → 用户已经接受过 neovim 候选,不再推
[Step 6] tool_call: compare_repos(source=vim-config, candidates=[helix, lapcat, amp])
         → 结构化对比 JSON
[Step 7] LLM 整理: 写最终 markdown 推荐,含 1-3 个候选 + 理由
[Step 8] final_answer → UI 渲染
```

最大步数 8 步(留余量)。

### 4.2 反向触发流程(主动发现)

```
[Step 1] user: "扫描我 stars 库里维护停滞的,找替代"
[Step 2] tool_call: get_user_stars_with_health()
         (新 tool, 复用 RepoHealthSheet 已有数据,只取 "stale" / "archived" 标记的)
[Step 3] 对每个 stale repo,跑主流程 3-7 步
[Step 4] LLM 整理: 聚合成一张「替代品总览表」,按原 repo 分类
```

**配额消耗**: 假设平均 30 个 stale repo,每个 3 步 ≈ 90+ 次 LLM 调用 → **必须分批 + 限速**。

### 4.3 配额策略

- 单仓库触发: **1 quota**(主流程 5-7 步聚合为 1 次 run)
- 反向触发(扫描全库): **按 stale 数 × 0.5 quota** 取整,设上限 10 quota/run
- **Pro only**: 单次 run 配额消耗 > 3 → 必须 Pro(`EntitlementGate` 拦截)

---

## 五、UI 落地

### 5.1 推荐复用 `RepoAIWindowContentView`

理由(见 `00-概览` §六):
- i18n / 暗色主题 / 流式渲染全部继承
- 不引入新设计系统
- 工具调用过程作为"系统消息"塞进 chat,用户能看见 agent 在干什么(不是黑盒)

### 5.2 触发入口

| 入口 | 触发方式 | 优先级 |
|---|---|---|
| **主流程**: Repo detail 页面右侧栏加「🔮 找替代品」按钮 | 单击触发 | 🥇 |
| **主流程**: Right-click menu on star row → "推荐替代品" | 右键触发 | 🥈 |
| **反向触发**: 设置页加「每周自动扫描 stars 库,找替代」toggle | 订阅触发 | 🥉 |

### 5.3 报告渲染结构

```
[Agent Report Window]
├── Header: 「🎯 替代品推荐: vim-config」
├── Subheader: "源仓库最后更新于 2024-03,以下 3 个候选更活跃"
├── Card 1: helix
│   ├── 一句话定位
│   ├── 关键指标(stars / last push / contributors)
│   ├── 与源仓库的差异
│   └── Actions: [⭐ Star] [📌 加入待考察] [🚫 已看过] [📖 在 GitHub 打开]
├── Card 2: amp
│   └── (同上)
├── Card 3: lapcat
│   └── (同上)
└── Footer: [🔄 再找一轮] [💾 保存为 note] [✕ 关闭]
```

### 5.4 关键交互

- **「🚫 已看过」**: 写入 `agent_feedback` 表,future 扫描跳过
- **「⭐ Star」**: 走 Starcat 已有 `StarService`,触发 GitHub star API + 本地 stars 库写入
- **「📌 加入待考察」**: 写入用户 tag(自动创建 "待考察" tag 如果不存在)
- **「💾 保存为 note」**: 把整个报告 markdown 存到 Starcat notes,关联到源 repo

### 5.5 AI 保守策略铁律

- **绝不**自动 star 候选仓库(必须用户主动点)
- **绝不**自动打 tag(必须用户主动点)
- **绝不**自动覆盖用户 notes
- 推荐结果**必须**在 UI 明显展示"这是 AI 生成的"

---

## 六、数据闭环:新增 / 复用表

### 6.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `stars` 表 | 用户 star 过的 repo 全集(数据源) |
| `repo` 表 | repo 元信息(可读 readme / language / topics) |
| `tag` + `repo_tag` | 用户 tag 体系(用于"加入待考察") |
| `note` | 保存报告 |
| `repo_health` (或 `RepoHealthSheet` 数据) | "维护停滞" 判定 |
| `EntitlementGate` + `quota` 表 | 配额拦截 |

### 6.2 新增 `agent_feedback` 表

```sql
CREATE TABLE agent_feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    agent_name TEXT NOT NULL,           -- 'alternatives_recommender'
    source_repo_id INTEGER NOT NULL,    -- 被推荐的源 repo
    candidate_repo_id INTEGER NOT NULL, -- 用户反馈的候选
    feedback TEXT NOT NULL,             -- 'accepted' | 'dismissed' | 'stared' | 'tagged'
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_agent_feedback_user ON agent_feedback(user_id, agent_name);
```

**为什么需要这张表**:
- 避免重复推荐(用户拒绝过的候选 30 天内不再推)
- 给 LLM 历史上下文("你之前给用户推过 X,他接受了 / 拒绝了")
- 未来训练 / 优化推荐质量

### 6.3 不引入新表的设计取舍

- 不存"推荐 run 完整日志"(太大了,真要排查走 `AIDebugLogger` 已有日志系统)
- 不存"推荐评分 / 排序细节"(LLM 输出不稳定,存了也没法对比)
- 不存"候选 repo 全量元信息"(直接下次再调 GitHub API,星标数据不存本地)

---

## 七、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| `AgentTool` 协议 + 4 个 tool 实现 | 新增 | 中 |
| `AgentOrchestrator` 通用编排循环 | 新增(跨 agent 复用) | 小(200 行内) |
| `AIClient` 加 function calling 支持 | 扩展 | 中(已有 streaming,加 tool_calls 字段) |
| `agent_feedback` 表 + DAO | 新增 | 小 |
| 推荐 UI(复用 chat 容器) | 扩展 | 小 |
| 报告 markdown 渲染(已有 markdown 组件?) | 扩展 | 小 |
| Repo detail「🔮 找替代品」按钮 | 新增 | 极小 |
| 「⭐ / 📌 / 🚫 / 💾」四个 action | 新增 | 中 |
| 反向触发的「每周自动扫描」toggle | 新增 | 中 |
| 单测(每个 tool 单独测 + orchestrator mock) | 新增 | 中 |
| i18n 词条(`agent.alternatives.*`) | 新增 | 小 |
| `AboutView.swift` 开源致谢(若新加 SPM) | 视情况 | 极小 |
| `docs/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: 中等。**核心难点不在框架,而在 `compare_repos` 的 prompt 设计**(让 LLM 输出稳定且有用的对比)。

---

## 八、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| LLM 推荐质量不稳定 | 中 | `compare_repos` 强制结构化输出(`@Generable` / JSON schema)+ 单测覆盖 3-5 个固定场景 |
| GitHub Search API rate limit | 中 | 走 Starcat 已有 `AuthSession` 复用用户 token,单 run 限制 tool call 总数 |
| 用户反感"AI 推销" | 中 | 默认不开启反向触发;主流程只在用户主动点时跑 |
| 候选 repo 也已 archived | 低 | `search_github_alternatives` 强制 `pushedAfter` 过滤 + 二次校验 `archived=false` |
| Tool 失败导致 agent 死循环 | 中 | `maxSteps=8` 硬上限 + 每步超时 30s |
| 推荐中文表达僵硬 | 低 | system prompt 明确"用用户偏好的语言(读 AppSettings),简洁口语化" |
| 配额消耗失控 | 中 | run 开始时 `estimatedQuota` 预扣,失败回滚 |

---

## 九、后续可拓展方向

1. **多模态候选**: 用 README 截图(GitHub social preview)做视觉对比
2. **协作过滤**: "和你 stars 库相似度高的其他 Starcat 用户,也 star 了 X"(需要匿名聚合)
3. **迁移成本评估**: 不只说"试试 X",而是给"从 vim-config 迁移到 helix 的工作量估计"
4. **反向**: "你已经 star 了 helix,要不要给 vim-config 提个 PR 推荐 helix"(社区贡献)

---

## 十、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿:基于 dong4j 讨论 + Starcat 现状评估 | Claude |
