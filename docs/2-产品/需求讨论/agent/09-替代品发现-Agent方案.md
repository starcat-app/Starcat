# 替代品发现 Agent 方案

> **文档定位**: 选中某个 repo,主动找同类项目并生成对比。**与 02 文档"替代品推荐"的差异点:02 是 agent 主动推送(后台触发),本方案是用户主动探索(按需触发)**。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板。
> **关联文档**:
> - [`02-替代品推荐-Agent方案.md`](02-替代品推荐-Agent方案.md):"被推荐"路径,本方案是它的"主动探索"补集
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)

---

## 一、用户故事

> 作为 Starcat 用户,我在浏览某个 repo 详情页(比如 5 年没更新的 vim 配置),点"**🔍 找同类项目**"按钮,agent 立刻:
> 1. 找 3-5 个功能相似但**更活跃**的替代
> 2. 给我一张**对比表**(功能 / 活跃度 / 生态 / 上手成本)
> 3. 我可以一键 star / 加对比 / 加入待考察

### 1.1 与 02 的差异

| 维度 | 02 替代品推荐(主动) | **09 替代品发现(被动)** |
|---|---|---|
| 触发 | 后台定期扫用户 stars 库 | 用户在某个 repo 页面**主动点** |
| 输出形式 | 周报式报告 | 嵌入当前页面的对比表 |
| 决策点 | "哪些 stars 该被推替代" | "这个具体 repo 的替代是谁" |
| 适用场景 | 老用户清理 stars 库 | 新用户探索单 repo |
| 触发频次 | 低(每周 1 次) | **高**(每次浏览都可能) |
| 工作量 | 中(走周报通道) | 小(单 repo 触发) |

---

## 二、核心价值

> **"在用户产生兴趣的瞬间,给他下一步选项"**——这是 GitHub Trending 给不了的"上下文敏感推荐"。

竞品分析:
- **GitHub 'Similar repositories' section**: 2018 年下线,2019 年短暂回归后再次下线,目前只显示"Forks"和"Used by"
- **StackOverflow 'Related'**: 文本相似度,不考虑维护活跃度
- **Starcat 本方案**: 显式对比"功能相似 + 更活跃 + 生态差异"

---

## 三、工具集

### 3.1 工具清单

```
Tool 1: get_source_repo_context
  输入:  owner, repo
  输出:  description / stars / language / topics / readme 前 500 tokens
  复用:  Starcat 已有 RepoAIContextProvider

Tool 2: search_similar_repos
  输入:  sourceRepo, minStars(默认 200), pushedAfter(默认 18 个月内), limit(默认 20)
  输出:  候选 repos[](description / stars / last_push / language / topics / license)
  复用:  GitHub Search API(走 AuthSession)

Tool 3: filter_by_differentiation
  输入:  sourceRepo, candidates[] (10-20 个)
  输出:  过滤后的 3-5 个"明显不同但功能相似"的 repos
  内部:  调 LLM 判定"功能等价度 + 差异化点"

Tool 4: compare_repos_table
  输入:  sourceRepo, alternatives[] (3-5 个)
  输出:  结构化对比表(JSON):
         [
           {name, positioning, activity_30d, contributors, issue_response_median_days,
            ecosystem_size, learning_curve, migration_difficulty_from_source}
         ]

Tool 5: get_user_existing_stars
  输入:  candidateRepoFullNames[]
  输出:  userStarred: Bool 字典(避免推"用户已经 star 过的"候选)
  复用:  Starcat 已有 stars 表
```

### 3.2 工具 schema 关键约束

- `search_similar_repos` 强制 `pushedAfter` 过滤(关键约束——否则会推 archived 仓库)
- `filter_by_differentiation` 候选数必须 10-20 个(太少 LLM 没得选,太多浪费 token)
- `compare_repos_table` 输出必须严格 JSON,前端按表渲染
- `get_user_existing_stars` 必须在最终输出前调用,避免推重复

---

## 四、Agent 编排循环

```
[Step 1] system: "你是 Starcat 替代品发现助手,基于源 repo 找功能相似但更活跃的替代"
[Step 2] user: "找 vim-config 的替代品"
[Step 3] tool_call: get_source_repo_context("dong4j", "vim-config")
         → description / Lua / 200 stars / 最后更新 2024-03
[Step 4] tool_call: search_similar_repos(
             source="vim-config",
             minStars=500,
             pushedAfter="2024-06-01",
             limit=20)
         → 12 个候选
[Step 5] tool_call: filter_by_differentiation(source=vim-config, candidates=12)
         → 4 个明显不同但功能相似:helix / amp / lapcat / neovim
[Step 6] tool_call: get_user_existing_stars(candidates=4)
         → user star 过 neovim,不再推
[Step 7] tool_call: compare_repos_table(source=vim-config, alternatives=3 [去掉 neovim])
         → 结构化对比表
[Step 8] LLM: 写一段开场白 + 解读对比表
[Step 9] final_answer → UI 渲染
```

最大 8 步,实际 5-6 步。

---

## 五、UI 落地

### 5.1 入口

**Repo detail 页面右侧栏加「🔍 找同类项目」按钮**(与"AI 摘要" / "健康度"按钮平级)。

### 5.2 弹窗 UI(嵌入 Repo detail 右侧抽屉)

```
┌─ 🔍 找同类项目: vim-config ──────────────────────┐
│                                                     │
│  源仓库: dong4j/vim-config                           │
│  最后更新: 2024-03(17 个月前)                       │
│  Stars: 200  Language: Lua                          │
│                                                     │
│  ── 找到 3 个明显不同但功能相似的替代 ──            │
│                                                     │
│  ┌────────────────────────────────────────────┐   │
│  │ 🌟 Helix                                    │   │
│  │ 定位: "Rust 写的现代化 modal 编辑器"        │   │
│  │ ⭐ 35k  📦 活跃(3 天前 commit)             │   │
│  │ 👥 180 contributors                         │   │
│  │ 📊 Issue 响应中位数: 1 天                   │   │
│  │ 📈 上手成本: 中(键位和 vim 不同)            │   │
│  │ 🔄 从 vim-config 迁移: 中(配置体系完全不同)│   │
│  │ [⭐ Star]  [📌 对比]  [📖 GitHub]            │   │
│  └────────────────────────────────────────────┘   │
│                                                     │
│  ┌────────────────────────────────────────────┐   │
│  │ 🚀 Amp                                      │   │
│  │ 定位: "VSCode 风格的终端编辑器"            │   │
│  │ ⭐ 28k  📦 活跃(1 周前 commit)             │   │
│  │ ...                                          │   │
│  └────────────────────────────────────────────┘   │
│                                                     │
│  ┌────────────────────────────────────────────┐   │
│  │ 🔧 Lapcat                                   │   │
│  │ ...                                          │   │
│  └────────────────────────────────────────────┘   │
│                                                     │
│  [💾 保存为 note]  [🔄 重新生成]  [✕ 关闭]         │
└─────────────────────────────────────────────────────┘
```

### 5.3 关键交互

- **「⭐ Star」**: 走 `StarService`(已有),触发 GitHub star API
- **「📌 对比」**: 把候选加到 Starcat 已有"对比视图"(若没有,需要新建一个轻量 `repo_compare` 表,见 §6.2)
- **「📖 GitHub」**: 在系统浏览器打开
- **「💾 保存为 note」**: 整张对比表存为 note,关联到源 repo
- **「🔄 重新生成」**: 重新跑(同样配额,新候选替换)
- **「📥 加入待考察」**: tag 候选为"待考察"

### 5.4 错误处理

| 错误 | UI 表现 |
|---|---|
| 找不到任何替代(极冷门 repo) | 提示"暂无明显替代,试试手动搜" |
| LLM 输出对比表字段缺失 | 自动重试 1 次,仍失败 → 显示"对比表生成中..." |
| GitHub rate limit | 走现有 rate limit 处理,弹 toast |
| 用户 star 过所有候选 | 提示"你已 star 过 X 个候选,以下是额外 N 个" |

---

## 六、数据闭环

### 6.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `stars` 表 + `repo` 表 | 数据源 + 用户历史去重 |
| `auth_session` | GitHub 鉴权 |
| `note` 表 | 保存对比报告 |
| `tag` + `repo_tag` | "待考察" tag |
| `StarService` | 一键 star |
| `RepoAIContextProvider` | 拉源 repo context |
| `EntitlementGate` + `quota` | Pro 拦截 |

### 6.2 新增 `repo_compare` 表(对比视图用)

```sql
CREATE TABLE repo_compare (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    source_repo_id INTEGER NOT NULL,
    candidate_repo_id INTEGER NOT NULL,
    compare_data_json TEXT NOT NULL,    -- LLM 输出的结构化对比表
    user_saved INTEGER NOT NULL,        -- 用户是否加入"我的对比列表"
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_repo_compare_user ON repo_compare(user_id, created_at DESC);
```

**为什么需要这张表**:
- 用户可能"📌 对比"多个候选,需要"我的对比列表"页面集中查看
- 后续可以做"对比报告"导出
- 不存 LLM 思考过程

### 6.3 不引入新表的设计取舍

- 不存"完整候选池"——下次重新跑即可
- 不存"用户每次浏览的替代品历史"——这是 `repo_compare` 的子集

---

## 七、付费与配额

| 用户档 | 体验 |
|---|---|
| **Free** | 每月 10 次"找同类";显示 top 3 候选(不显示完整对比表) |
| **Pro** | 不限次数;显示完整对比表;可"📌 对比"无限候选;可保存为 note |

- 单次 run 配额: **1 quota**(单 repo 触发,工具体量小)
- 配额回滚:GitHub rate limit 失败回滚,LLM 失败不回滚

---

## 八、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| 5 个 Tool 实现 | 新增 | 中(与 02 大量共用,只差 `get_user_existing_stars` 1 个新) |
| `repo_compare` 表 + DAO | 新增 | 小 |
| 「🔍 找同类项目」按钮 | 新增 | 极小 |
| 弹窗 UI(对比表 + 候选卡片) | 新增 | 中 |
| 「📌 对比」 → 集中对比视图 | 新增(轻量列表页) | 小 |
| 单测(候选过滤 / 重复 star 去重) | 新增 | 中 |
| i18n 词条(`agent.discover.*`) | 新增 | 小 |
| `docs/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: **小**。与 02 替代品推荐并行做可省 40% 工作(共用 80% 工具代码)。

---

## 九、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| 候选全是"老牌已 archived"(被 LLM 偏爱) | 中 | `search_similar_repos` 强制 `pushedAfter` + 二次校验 `archived=false` |
| 对比表字段用户看不懂("issue 响应中位数") | 中 | UI 加 tooltip 解释;中文化字段名 |
| 用户在已 star 的候选上重复 star | **低** | `get_user_existing_stars` 强制过滤;UI 显示"已 star"状态而非"Star"按钮 |
| LLM 解读带主观偏向(吹某个候选) | 中 | prompt 强调"客观对比,不偏袒";对比表数据 LLM 不能改 |
| 「📌 对比」滥用(用户对比 100 个) | 低 | Pro 限 50 个/集合,Free 限 5 个 |
| 与 02 替代品推荐结果不一致 | 中 | 共用 `compare_repos` tool,保证算法一致 |

---

## 十、后续可拓展方向

1. **跨 star 库对比**: "对比 3 个用户的 stars 库,推荐共同缺失但都应该 star 的" (需用户授权)
2. **"避免替代"反向**: "哪些 repo **不是** 这个的替代"(用户已经调研过)
3. **替代品时间线**: "这个 repo 的替代品在 2020/2022/2024/2026 分别是哪些"(展示生态演变)
4. **付费/开源/平台筛选**: 在对比表上加筛选条件
5. **替代品活跃度预警**: 用户已 star 的某 repo 突然出现"被广泛替代"信号时推送

---

## 十一、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿 | Claude |
