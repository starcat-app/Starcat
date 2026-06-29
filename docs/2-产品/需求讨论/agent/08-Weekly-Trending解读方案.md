# GitHub Weekly Report Agent 方案

> **文档定位**: Starcat 内置 Agent 能力方案。以「GitHub Weekly Report Agent」为首个预置 Agent,基于 trending-api / Weekly / 用户选中 repo,自动生成类似阮一峰 Weekly 的热门开源项目周刊,并派生 Markdown / 图文卡 / HTML / 视频文案等产出物。
> **状态**: 细化方案稿(2026-06-28),等 dong4j 拍板。
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`03-Starred-Repo-周报-Agent方案.md`](03-Starred-Repo-周报-Agent方案.md):对比——03 偏用户 stars 库个人周报,本方案偏全网热门 / 手选 repo 的公开内容周刊
> - [`16-Agent底层平台技术方案.md`](16-Agent底层平台技术方案.md):Agent Workspace / Runtime / Tool / Artifact 底座
> - [`17-GitHubWeeklyReportAgent技术实现方案.md`](17-GitHubWeeklyReportAgent技术实现方案.md):本 Agent 的工程落地方案
> - [`../CLAUDE.md`](../CLAUDE.md):AI 保守策略(预览 → 确认 → 写入)

---

## 一、定位

本方案不是一个固定表单式「周刊生成器」,而是 Starcat 内置 Agent 工作台中的一个预置 Agent。

核心定位:

> Starcat 提供一个覆盖主窗口的 Agent 工作台。用户选择内置 Agent 后,通过自然语言描述目标,Agent 自主规划步骤、调用工具、展示执行过程,最后生成可编辑、可导出、可继续追问的产出物。

`GitHub Weekly Report Agent` 是首个重点 Agent:

- 定期或手动整理本周热门开源项目
- 支持用户从 Trending / Weekly / Discovery / Manage 中手动勾选 repo
- 生成类似阮一峰 Weekly 的中文技术周刊
- 可继续派生小红书图文卡、HTML 展示页、视频脚本 / 分镜 / 字幕文案
- 图片通过 AI 图片生成 API 作为周刊视觉资产生成,不把 Starcat 做成独立设计器

---

## 二、用户故事

### 2.1 普通运行

> 作为技术博主 / 内容创作者,我想每周打开 Starcat 的 Agent 工作台,输入「帮我生成本周 GitHub 热门项目周刊」,Agent 自动拉取热门 repo、筛选主题、生成周刊正文和配图,让我复制即可发布到博客、公众号、小红书或视频工具。

### 2.2 手选 repo

> 作为 Starcat 用户,我想在 Trending / Weekly / Manage 中勾选 5-20 个 repo,点击 Agent,让它只基于这些 repo 生成一期专题周刊,例如「本周 AI Agent 工具专辑」。

### 2.3 定时运行

> 作为长期维护技术周刊的用户,我想配置一个每周一上午自动运行的 Agent,它先生成草稿和素材,但最终发布前仍然需要我确认。

### 2.4 多形态派生

> 作为内容创作者,我希望同一份周刊母稿可以继续转换为 Markdown、小红书 9 图文案、HTML 页面、B 站视频口播稿。不同形态应该内容一致,只是表达方式不同。

---

## 三、Agent 工作台整体设计

### 3.1 入口

主窗口右上角新增 `Agent` 入口。点击后不弹小 sheet,而是切换到覆盖当前三栏主窗口的 Agent 工作台。

入口来源:

| 入口 | 行为 |
|---|---|
| 主窗口右上角 `Agent` | 打开 Agent 工作台,默认展示最近使用的 Agent |
| Trending / Weekly / Discovery / Manage 多选后 `Agent` | 打开 Agent 工作台,并把选中 repo 注入为当前上下文 |
| Repo 详情页右上角 `Agent` | 打开 Agent 工作台,并把当前 repo 注入为上下文 |
| 定时任务通知 | 打开对应 Agent 的运行结果或草稿 |

交互原则:

- `Agent` 是一个模式切换,不是临时弹窗
- 工作台需要有明确 `返回主界面` 操作
- 从列表 / 详情页进入时,Agent 输入框里预填上下文提示,但不自动执行高成本任务

### 3.2 布局

```
┌────────────────────────────────────────────────────────────────────┐
│ Agent 工作台                                            返回主界面 │
├───────────────────┬────────────────────────────────────────────────┤
│ 内置 Agent 列表    │ 执行面板                                       │
│                   │                                                │
│ GitHub 周刊        │ 当前 Agent: GitHub Weekly Report               │
│ Repo 解读          │ 当前任务: 生成本周热门开源项目周刊              │
│ 本地文档整理       │ 状态: 正在筛选候选 repo                         │
│ Release 追踪       │                                                │
│ 自定义 Agent       │ ┌─ 步骤时间线 ───────────────────────────────┐ │
│                   │ │ 1. 读取 trending-api 数据                  │ │
│                   │ │ 2. 筛选 AI Agent 相关 repo                 │ │
│                   │ │ 3. 聚类主题                                │ │
│                   │ │ 4. 生成周刊母稿                            │ │
│                   │ │ 5. 生成图片 prompt                         │ │
│                   │ │ 6. 生成产出物                              │ │
│                   │ └────────────────────────────────────────────┘ │
│                   │                                                │
│                   │ ┌─ 产出物 ──────────────────────────────────┐ │
│                   │ │ Markdown | 小红书 | HTML | 视频文案 | 图片 │ │
│                   │ └────────────────────────────────────────────┘ │
│                   │                                                │
│                   │ ┌────────────────────────────────────────────┐ │
│                   │ │ 告诉 Agent 你要做什么...                  │ │
│                   │ └────────────────────────────────────────────┘ │
└───────────────────┴────────────────────────────────────────────────┘
```

### 3.3 左侧 Agent 列表

左侧不是普通导航,而是可运行能力列表。

每个 Agent 卡片包含:

- 名称: `GitHub Weekly Report`
- 简述: `整理热门开源项目并生成多形态周刊`
- 能力标签: `trending` / `report` / `image` / `schedule`
- 状态: `未配置` / `已启用定时` / `最近运行成功` / `需要授权`
- 最近运行时间
- 快捷操作: `运行` / `配置` / `历史`

首批内置 Agent 建议:

| Agent | 用途 | 优先级 |
|---|---|---|
| GitHub Weekly Report | 热门 repo 周刊生成 | P0 |
| Repo Insight | 单 repo 深度解读 / 对比 / 总结 | P1 |
| Local Docs Organizer | 本地文档整理与摘要 | P1 |
| Release Watcher | Release 订阅追踪与变更总结 | P1 |
| Custom Agent | 用户自定义 prompt + 工具权限 | P2 |

### 3.4 右侧执行面板

右侧大面板采用「对话 + 步骤 + 产出物」结构。

区域:

1. **任务头部**
   - 当前 Agent
   - 当前任务标题
   - 运行状态
   - 本次上下文来源
   - quota / 图片次数预估

2. **步骤时间线**
   - 展示 Agent 每一步计划和执行结果
   - 每一步可展开查看输入、工具调用、输出摘要
   - 失败步骤显示错误和重试入口

3. **Artifact 区**
   - 展示最终和中间产出物
   - 使用 tabs: `周刊 Markdown` / `小红书图文` / `HTML 页面` / `视频文案` / `图片素材` / `运行日志`

4. **底部对话框**
   - 用户输入自然语言目标
   - 支持继续追问和局部修改
   - 支持 slash command,如 `/schedule`、`/export`、`/regenerate`

---

## 四、GitHub Weekly Report Agent 能力模型

### 4.1 输入来源

| 来源 | 说明 |
|---|---|
| `trending-api` | 自建 trending 数据源,用于本周热门 repo |
| Weekly feed | Starcat 已有 Weekly 聚合数据 |
| Discovery feed | AI Discovery / HN 等发现数据 |
| 用户手动勾选 repo | 从列表或详情页注入上下文 |
| 用户自定义主题 | 例如「只看 Swift / macOS / AI Agent」 |
| 历史运行配置 | 定时 Agent 复用上一次规则 |

### 4.2 Agent 可调用工具

```
Tool 1: fetch_trending_repos
  输入: since, language?, topic?, top
  输出: TrendingRepo[]
  说明: 走 Starcat 自建 trending-api,不是 GitHub 官方 Trending API。

Tool 2: fetch_weekly_feed
  输入: weekStart?, source?, language?, starsRange?
  输出: WeeklyFeedItem[]
  说明: 复用现有 Weekly 远端数据。

Tool 3: resolve_selected_repos
  输入: selectionSnapshot[]
  输出: RepoContext[]
  说明: 把用户在 UI 中勾选的 repo 转换为 Agent 可读上下文。

Tool 4: get_repo_overview
  输入: owner, repo
  输出: description / README 摘要 / release / stars / topics / 活跃度
  说明: 复用 Starcat repo 详情和 AI 上下文能力。

Tool 5: cluster_report_topics
  输入: RepoContext[]
  输出: ReportTopic[]
  说明: 聚类为 3-5 个主题,供周刊结构使用。

Tool 6: generate_weekly_report
  输入: sourceSnapshot, topics, styleGuide
  输出: WeeklyReportDraft
  说明: 生成 canonical weekly report,后续所有形态都从它派生。

Tool 7: generate_artifact
  输入: WeeklyReportDraft, artifactType, styleGuide
  输出: ArtifactDraft
  说明: 生成 Markdown / 小红书 / HTML / 视频文案。

Tool 8: generate_image_prompts
  输入: WeeklyReportDraft, imagePlan
  输出: ImagePrompt[]
  说明: 先生成图片 prompt,用户确认后才调用图片生成 API。

Tool 9: generate_images
  输入: ImagePrompt[], provider, size
  输出: ImageArtifact[]
  说明: 调用图片生成 API,高成本操作必须可预估、可确认。

Tool 10: export_artifacts
  输入: Artifact[], targetDirectory
  输出: filePath[]
  说明: 导出 Markdown / 图片 zip / HTML / 字幕 / 脚本。
```

### 4.3 Agent 执行循环

```
User Prompt
  ↓
Intent Parser
  ↓
Agent Planner
  ↓
Tool Calls + Step Timeline
  ↓
Canonical Weekly Report
  ↓
Artifact Builder
  ↓
User Review
  ↓
Export / Save / Schedule / Continue Chat
```

关键约束:

- Agent 可以自主规划步骤,但高成本操作需要确认
- 最终导出和保存前必须预览
- 生成图片前必须先展示 prompt 和费用预估
- 如果用户只要求「整理思路」,不得自动调用图片 API 或导出文件

---

## 五、Weekly Report 内容结构

### 5.1 Canonical Weekly Report

所有输出形态先生成统一母稿,避免 Markdown、小红书、视频文案各自重新理解 repo 导致内容不一致。

建议结构:

```json
{
  "title": "本周 GitHub 热门项目观察",
  "subtitle": "AI Agent 工具链继续升温",
  "intro": "...",
  "trendSummary": [
    "趋势 1",
    "趋势 2",
    "趋势 3"
  ],
  "topics": [
    {
      "title": "AI Agent 工具链",
      "summary": "...",
      "repos": [
        {
          "owner": "owner",
          "name": "repo",
          "whatItIs": "它是什么",
          "whyTrending": "为什么本周值得关注",
          "highlights": ["亮点 1", "亮点 2"],
          "bestFor": "适合谁",
          "caveats": "风险 / 限制",
          "sourceEvidence": ["README", "stars growth", "release"]
        }
      ]
    }
  ],
  "closing": "...",
  "imagePlan": [
    {
      "target": "cover",
      "prompt": "..."
    }
  ]
}
```

### 5.2 写作风格

内置风格:

| 风格 | 说明 |
|---|---|
| 技术周刊 | 接近阮一峰 Weekly,信息密度高,克制点评 |
| 科普解释 | 对非深度技术读者友好,解释背景和使用场景 |
| 犀利点评 | 更重判断,强调趋势、风险和取舍 |
| 内容平台 | 更适合小红书 / B 站,标题更强但不能夸大事实 |
| 自定义 | 用户提供参考文案或风格说明 |

风格是 Agent 的参数,不是固定表单。用户可以直接说:

```text
写得像阮一峰 Weekly,少一点营销味,每个项目都加一句自己的判断。
```

---

## 六、Artifact 体系

### 6.1 Artifact 类型

| Artifact | 内容 | 产出文件 |
|---|---|---|
| 周刊 Markdown | 完整正文,适合博客 / 公众号二次编辑 | `.md` |
| 小红书图文 | 9 张卡文案 + 配文 + 标签 + 可选图片 | `.zip` |
| HTML 页面 | 可分享静态页面,轻量动效 | `.html` + assets |
| 视频文案 | 口播稿 / 分镜 / 字幕 / AI 视频 prompt | `.md` + `.srt` |
| 图片素材 | 封面 / repo 概念图 / 卡片背景 | `.png` / `.jpg` |
| 运行日志 | 工具调用、输入、输出摘要、错误 | app 内查看 |

### 6.2 小红书图文

生成逻辑:

1. 从 canonical report 提炼 9 张卡结构
2. 每张卡先生成文案和图片 prompt
3. 用户确认 prompt 后调用图片生成 API
4. 图片与文字组合成导出包

卡片建议:

| 卡片 | 内容 |
|---|---|
| 1 | 封面: 本周 GitHub 热门项目 |
| 2 | 本周趋势总览 |
| 3-7 | 精选 repo 或主题 |
| 8 | 值得关注的趋势判断 |
| 9 | 总结 + 互动问题 |

### 6.3 HTML 页面

HTML 是周刊展示形态,不是视频生成工具。

初版能力:

- 静态 HTML
- 内嵌或相对路径 CSS
- 支持封面图和项目图
- 轻量 fade / slide 动效
- 可直接导出到本地目录

### 6.4 视频文案

视频能力只到「文案包」,不生成 mp4。

输出内容:

- 5-8 分钟口播稿
- 分镜脚本
- 字幕 `.srt`
- 画面提示词
- 可复制到外部 AI 视频工具的 prompt

---

## 七、关键交互逻辑

### 7.1 上下文注入

从不同页面进入 Agent 时,系统注入不同上下文:

| 来源 | 注入内容 |
|---|---|
| Trending 列表 | 当前筛选条件、可见 repo、选中 repo |
| Weekly 列表 | 当前期号、来源、筛选条件、选中 repo |
| Manage 列表 | 用户 stars 中的选中 repo |
| Repo 详情页 | 当前 repo 完整上下文 |
| 主入口 | 无特定 repo,由用户自然语言指定 |

输入框示例:

```text
已选中 8 个 repo。你可以说:「基于这些 repo 生成一期 AI Agent 专题周刊」。
```

### 7.2 步骤时间线

步骤状态:

- `等待中`
- `执行中`
- `需要确认`
- `已完成`
- `失败`
- `已跳过`

每一步展示:

- 步骤名称
- 工具名称
- 输入摘要
- 输出摘要
- 耗时
- quota / 图片次数消耗

示例:

```text
步骤 3: 聚类主题
工具: cluster_report_topics
输入: 24 个 repo
输出: 4 个主题
耗时: 8.2s
```

### 7.3 用户确认点

必须确认:

- 开始高成本图片生成
- 开启定时任务
- 导出到文件系统
- 保存到 Notes / 历史库
- 使用外部 AI provider API key

可以自动执行:

- 拉取 trending / weekly 数据
- 读取本地缓存
- 生成纯文本草稿
- 生成图片 prompt
- 生成导出预览

### 7.4 继续对话与局部修改

用户可以在产出后继续输入:

```text
第 3 个项目写得太像广告,改成更客观的技术点评。
```

Agent 应该只修改对应 artifact 节点,而不是整轮重跑。

支持的局部操作:

- 重写标题
- 重写导语
- 重写某个 repo 段落
- 删除某个 repo
- 调整 repo 顺序
- 重生成某张小红书卡
- 重生成某张图片 prompt
- 把 Markdown 转为视频口播稿

---

## 八、定时 Agent

定时能力属于 Agent 平台,不是 Weekly Report 的孤立配置。

### 8.1 配置项

| 配置 | 示例 |
|---|---|
| 运行频率 | 每周一 09:00 |
| 数据范围 | trending-api top 50 |
| 主题过滤 | AI Agent / Swift / macOS |
| 默认产物 | Markdown + 小红书文案 |
| 图片策略 | 只生成 prompt / 自动生成封面 / 每个项目一张 |
| 确认策略 | 运行前确认 / 产出后确认 / 图片前确认 |
| 通知 | 运行完成后通知 |

### 8.2 保守策略

默认策略:

- 定时任务可以自动拉取数据、聚类、生成文本草稿
- 图片生成默认需要用户确认
- 对外发布、写入 Notes、导出文件默认需要用户确认
- 失败时保留已完成步骤和中间 artifact

### 8.3 历史与复跑

每次定时运行形成一条 run:

- 可查看输入快照
- 可查看步骤日志
- 可查看产出物
- 可基于这次 run 继续对话
- 可复制配置创建新定时 Agent

---

## 九、数据模型草案

### 9.1 Agent 定义

```sql
CREATE TABLE agent_definition (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    icon_name TEXT NOT NULL,
    capabilities_json TEXT NOT NULL,
    is_builtin INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

### 9.2 Agent 运行

```sql
CREATE TABLE agent_run (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    title TEXT NOT NULL,
    user_prompt TEXT NOT NULL,
    context_json TEXT NOT NULL,
    status TEXT NOT NULL, -- pending | running | waiting_confirmation | succeeded | failed | cancelled
    started_at INTEGER NOT NULL,
    finished_at INTEGER,
    quota_cost INTEGER NOT NULL DEFAULT 0,
    image_cost INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_agent_run_agent ON agent_run(agent_id, started_at DESC);
```

### 9.3 步骤日志

```sql
CREATE TABLE agent_run_step (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    title TEXT NOT NULL,
    tool_name TEXT,
    status TEXT NOT NULL,
    input_summary TEXT,
    output_summary TEXT,
    error_message TEXT,
    started_at INTEGER,
    finished_at INTEGER
);
CREATE INDEX idx_agent_run_step_run ON agent_run_step(run_id, step_index);
```

### 9.4 产出物

```sql
CREATE TABLE agent_artifact (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    type TEXT NOT NULL, -- markdown | xhs_cards | html | video_script | image | log
    title TEXT NOT NULL,
    content_json TEXT,
    file_path TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX idx_agent_artifact_run ON agent_artifact(run_id, created_at);
```

### 9.5 定时任务

```sql
CREATE TABLE agent_schedule (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    title TEXT NOT NULL,
    prompt_template TEXT NOT NULL,
    schedule_rule TEXT NOT NULL,
    context_preset_json TEXT NOT NULL,
    confirmation_policy_json TEXT NOT NULL,
    is_enabled INTEGER NOT NULL DEFAULT 1,
    last_run_at INTEGER,
    next_run_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

设计取舍:

- 不把大图片 / HTML assets 放进 SQLite,只存路径
- 必须保存 source snapshot 和 artifact JSON,方便复跑和局部修改
- 未上线项目不做旧 schema 兼容逻辑,表结构可以随方案推进直接调整

---

## 十、权限、配额与成本

### 10.1 权限

| 能力 | 权限要求 |
|---|---|
| 读取 trending-api | 网络访问 |
| 读取用户 stars | GitHub AuthSession |
| 调用文本 LLM | AI provider 配置 / Pro |
| 调用图片生成 API | 图片 provider 配置 / Pro |
| 写文件导出 | 用户选择目录 |
| 定时运行 | 用户显式开启 |

### 10.2 配额

建议按操作拆分:

| 操作 | 配额 |
|---|---|
| 文本周刊生成 | 基础 quota |
| 小红书文案派生 | 少量追加 quota |
| HTML / 视频文案派生 | 少量追加 quota |
| 图片 prompt 生成 | 文本 quota |
| 图片生成 | 独立 image quota |

运行前展示预估:

```text
预计消耗:
- 文本生成: 4 quota
- 图片生成: 6 image credits
- 数据读取: 免费
```

---

## 十一、失败恢复

| 失败点 | 恢复策略 |
|---|---|
| trending-api 失败 | 提示重试,可切换到用户选中 repo |
| LLM 文本失败 | 保留 source snapshot,支持重试当前步骤 |
| 图片生成失败 | 保留图片 prompt,允许换 provider 或跳过图片 |
| 导出失败 | 保留 artifact,允许重新选择目录 |
| 定时任务失败 | 记录失败 run,通知用户 |

关键原则:

- 失败不丢已完成步骤
- 高成本步骤失败不自动无限重试
- 用户永远可以从某一步继续

---

## 十二、实施拆分

### Phase 1: Agent 工作台骨架

- 主窗口右上角 Agent 入口
- 覆盖式 Agent 工作台
- 左侧内置 Agent 列表
- 右侧对话输入、步骤时间线、Artifact tabs
- `agent_run` / `agent_run_step` / `agent_artifact` 基础存储

### Phase 2: GitHub Weekly Report Agent 文本闭环

- 接入 trending-api / Weekly / 手选 repo 上下文
- Agent planner 生成执行步骤
- 生成 canonical weekly report
- Markdown artifact 预览、编辑、复制、导出
- 运行历史

### Phase 3: 多形态 Artifact

- 小红书 9 卡文案
- HTML 页面 artifact
- 视频脚本 / 分镜 / 字幕文案
- 局部重生成

### Phase 4: 图片生成

- 图片 prompt 生成与确认
- 接入图片生成 API
- 图片 artifact 管理
- 小红书图文 zip 导出

### Phase 5: 定时 Agent

- `agent_schedule`
- 每周定时生成草稿
- 通知与确认策略
- 从历史 run 复用配置

---

## 十三、关键风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| Agent 工作台过早平台化,压过核心管理功能 | 高 | 首期只做 1 个内置 Agent,平台能力服务于 Weekly 场景 |
| Agent 自主步骤不可控 | 高 | 步骤时间线透明展示,高成本 / 写入 / 导出必须确认 |
| AI 周刊出现事实错误 | 高 | 保存 source evidence,每个 repo 显示依据,支持用户局部修正 |
| 图片生成成本失控 | 高 | 先生成 prompt,确认后才调用图片 API,运行前展示 image credits |
| 多形态内容不一致 | 中 | 先生成 canonical report,其它 artifact 从母稿派生 |
| UI 变成复杂配置面板 | 中 | 主交互保持对话式,配置只作为 Agent 设置 |
| 定时任务打扰用户 | 中 | 默认关闭,开启后可设置确认策略和通知频率 |

---

## 十四、开放问题

1. Agent 工作台是否完全覆盖主窗口,还是保留顶部全局 toolbar?
2. 首期 Agent 列表是否只展示 `GitHub Weekly Report`,其它 Agent 用 disabled 预告?
3. 图片生成 provider 是否复用现有 AI Provider 配置,还是单独配置 image provider?
4. 小红书 artifact 是否首期就生成真实 PNG,还是先只生成卡片文案 + 图片 prompt?
5. 定时任务首期是否进入实现范围,还是先做手动运行 + 保存配置?

---

## 十五、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-28 | 重写为内置 Agent 工作台 + GitHub Weekly Report Agent 细化方案 | Codex |
| 2026-06-27 | 初稿 | Claude |
