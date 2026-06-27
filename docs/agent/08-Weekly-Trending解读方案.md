# Weekly / Trending 解读(多形态内容生成 Agent)

> **文档定位**: 综合 GitHub Trending + Weekly 数据,自动生成多形态中文内容(小红书图文卡 / 博客 markdown / B 站视频文案 + HTML 动画)。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板。
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`03-Starred-Repo-周报-Agent方案.md`](03-Starred-Repo-周报-Agent方案.md):对比——03 是基于用户 stars 库,本方案是全网 Trending + 内容创作
> - [`../CLAUDE.md`](../CLAUDE.md):AI 保守策略(预览 → 确认 → 写入)

---

## 一、用户故事

> 作为 Starcat 用户(技术博主 / 内容创作者),我想:
> 1. **每周一** 看到一份"本周 GitHub 热门项目解读",我**复制即可**发布到小红书 / 个人博客 / B 站
> 2. 不用自己写文案,不用找资料,不用做图
> 3. 我可以选输出形态(小红书 9 图卡 / 长博客 / 5 分钟视频脚本 + 动画)
> 4. 文字风格我可以预设("极客风" / "科普风" / "段子手")

### 1.1 三个输出形态

| 形态 | 内容 | 文件 |
|---|---|---|
| **小红书图文卡** | 9 张 1080×1440 PNG + 配文(150 字内) + 标签 | `.zip` 含 PNG + 配文 .md |
| **博客 markdown** | 完整长文(1500-3000 字),配图表,SEO 友好 | `.md` |
| **B 站视频** | 5 分钟脚本 + HTML 动画(可导出为视频) + 字幕 | `.html`(动画) + `.srt`(字幕) + `.md`(脚本) |

---

## 二、核心价值

> **"让 Starcat 成为内容创作者的素材工厂"**——把"刷 GitHub → 写文案 → 做图 / 剪视频"的 4 小时工作压成 1 分钟。

差异化:
- 主流"GitHub 周报"工具只给列表(README / digest),不帮做内容
- 主流"内容生成 AI"不懂 GitHub 趋势,只懂通用话题
- **两者结合,Starcat 独占**

---

## 三、工具集

### 3.1 工具清单(数据采集 + 形态生成)

```
Tool 1: fetch_github_trending
  输入:  language?(可选), since(默认 daily), top(默认 30)
  输出:  TrendingRepo[] (含 stars_today / total_stars / description / language / topics)
  复用:  走 GitHub Trending API(需鉴权,Starcat 已有 AuthSession)

Tool 2: fetch_weekly_data
  输入:  weekStart(默认上周一)
  输出:  WeeklyStats(本周新增 stars 数 / 增长最快 repo top 10 / 新晋 top 100)
  复用:  GitHub API + 缓存(避免重复抓)

Tool 3: get_repo_overview
  输入:  owner, repo
  输出:  description / readme 前 800 tokens / 最近 3 个 release / 维护活跃度
  复用:  Starcat 已有 RepoAIContextProvider

Tool 4: cluster_and_pick_topics
  输入:  TrendingRepo[] (10-30 个)
  输出:  3-5 个主题聚类,每类给一句话主题 + 代表 repo top 3
  内部:  调 LLM,@Generable 强制 JSON 结构

Tool 5: generate_xiaohongshu_post
  输入:  topics(主题聚类), stylePreset(极客/科普/段子手), targetCount(默认 9 张)
  输出:  9 张卡片的文本(每张 30-60 字 + emoji)+ 配文
  内部:  调云端 LLM(必须,中文 + 风格化强需求)

Tool 6: generate_blog_markdown
  输入:  topics, stylePreset, targetLength(默认 2000 字)
  输出:  完整 markdown 博客(含 H2/H3、代码块、引用、CTA)

Tool 7: generate_bilibili_script
  输入:  topics, stylePreset, targetDuration(默认 5 分钟)
  输出:  视频脚本(分镜 + 旁白 + 字幕)+ 关键节点建议(放图 / 放 demo)

Tool 8: render_xiaohongshu_images
  输入:  cards(9 张文本), template(配色 / 字体)
  输出:  9 个 PNG 文件(1080×1440)
  内部:  Core Graphics 绘制(纯本地,无 AI)

Tool 9: render_bilibili_html_animation
  输入:  script(分镜 + 旁白), template
  输出:  单 HTML 文件,内嵌 CSS 动画 + JS 控制器
  内部:  模板化的 HTML 模板,占位由 LLM 文本填充
```

### 3.2 工具 schema 关键约束

- `fetch_github_trending` 默认 daily,如果想看 weekly / monthly 必须显式传
- `cluster_and_pick_topics` 主题数 3-5 个(少则无层次,多则没重点)
- `generate_xiaohongshu_post` **必须**9 张卡(小红书最优格式),不能少不能多
- `render_*` 必须支持自定义字体 / 配色(用户风格预设)

---

## 四、Agent 编排循环

### 4.1 主流程(用户选了"小红书"形态)

```
[Step 1] system: "你是 Starcat 内容创作助手,把 GitHub 趋势做成小红书爆款"
[Step 2] user: "生成这周 GitHub 趋势,小红书形态,极客风"
[Step 3] tool_call: fetch_github_trending(since=daily, top=30)
[Step 4] tool_call: fetch_weekly_data(weekStart=上周一)
[Step 5] tool_call: cluster_and_pick_topics(repos=30)
         → 4 个主题: "AI Agent 实战" / "Rust CLI 工具" / "macOS 原生" / "LLM 推理优化"
[Step 6] 对每个主题的代表 repo,tool_call: get_repo_overview(...)
[Step 7] tool_call: generate_xiaohongshu_post(topics=4, style=极客, count=9)
         → 9 张卡文本 + 配文
[Step 8] tool_call: render_xiaohongshu_images(cards=9, template=深色科技)
         → 9 个 PNG
[Step 9] final_answer: 配文 + 9 PNG → UI 预览 + "导出 .zip"
```

最大 9 步,实际 7-8 步。

### 4.2 三个形态的差异

| 步骤 | 小红书 | 博客 | B 站视频 |
|---|---|---|---|
| 数据采集 | 1-4 | 1-4 | 1-4 |
| 聚类 | 5 | 5 | 5 |
| 文本生成 | 7 (generate_xiaohongshu_post) | 7 (generate_blog_markdown) | 7 (generate_bilibili_script) |
| 渲染 | 8 (render_xiaohongshu_images) | 无(直接 markdown) | 8 (render_bilibili_html_animation) |
| 输出 | .zip | .md | .html + .srt + .md |

### 4.3 配额策略

- 单次 run = **3 quota**(基础)+ 1 quota/形态 = 4-6 quota
- **Pro only**(高消耗 + 价值高 + Free 用不到)

---

## 五、UI 落地

### 5.1 入口

**主窗口左侧栏加「🎬 创作」section**(在 Activity 旁边),折叠可隐藏:
- "本周趋势 · 小红书"
- "本周趋势 · 博客"
- "本周趋势 · 视频"
- "自定义主题创作"(让用户输入主题)

### 5.2 创作流程 UI

```
Step 1: 选择形态
  ⚪ 小红书图文 (9 张 1080×1440)
  ⚪ 博客 markdown
  ⚪ B 站视频脚本 + HTML 动画

Step 2: 风格预设
  ⚪ 极客风 (硬核 / 技术细节)
  ⚪ 科普风 (通俗 / 类比)
  ⚪ 段子手 (幽默 / 玩梗)
  ⚪ 自定义 (粘贴示例文案让 AI 学)

Step 3: 主题范围(可选,默认全网)
  ⚪ 全部
  ⚪ 指定语言
  ⚪ 指定领域(用 1-2 个关键词)

[🚀 开始创作]
```

### 5.3 创作过程 UI(复用 `RepoAIWindowContentView`)

- 左侧 chat 流:每步 tool 调用的 progress
- 右侧实时预览:
  - 小红书:边生成边出卡(第 3 张出时,前 2 张可滚动预览)
  - 博客:实时渲染 markdown
  - 视频:HTML 动画实时播放

### 5.4 最终输出 UI

```
┌─ 本周 GitHub 趋势 · 小红书 ─────────────────┐
│                                              │
│  配文(可编辑):                              │
│  ┌────────────────────────────────────────┐ │
│  │ 这周 GitHub 又炸了 4 个新项目...        │ │
│  │ ...                                      │ │
│  └────────────────────────────────────────┘ │
│                                              │
│  9 张预览(图缩略):                          │
│  [1] [2] [3]                                │
│  [4] [5] [6]                                │
│  [7] [8] [9]                                │
│                                              │
│  [💾 导出 .zip] [📋 复制配文] [🔄 重新生成]  │
│  [✏️ 编辑文案] [✕ 关闭]                      │
└──────────────────────────────────────────────┘
```

### 5.5 关键交互

- **「💾 导出 .zip」**: 9 PNG + 配文 .md + 标签 .txt 打包,放到用户选的目录
- **「📋 复制配文」**: 配文复制到剪贴板
- **「✏️ 编辑文案」**: 9 张卡的文字可单张编辑,改完重渲染单张 PNG(不全量重做)
- **「🔄 重新生成」**: 重新跑 agent run(同样配额)

---

## 六、数据闭环

### 6.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `auth_session`(GitHub token) | 调 GitHub API 鉴权 |
| `AIClient` / AI Proxy | 调 LLM 生成文本 |
| `EntitlementGate` + `quota` | Pro 拦截 + 配额扣减 |
| `AppSettings` | 保存用户风格预设 |
| `Note` | (可选)把生成的博客 / 视频脚本存为 note |

### 6.2 新增 `content_creation` 表(仅存元信息)

```sql
CREATE TABLE content_creation (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    format TEXT NOT NULL,           -- 'xiaohongshu' | 'blog' | 'bilibili'
    style_preset TEXT NOT NULL,
    topic_scope TEXT,               -- 用户指定的主题范围,NULL = 全网
    created_at INTEGER NOT NULL,
    note_id INTEGER,                -- 用户"保存为 note"时关联
    file_path TEXT                  -- 用户导出文件的本地路径
);
CREATE INDEX idx_content_creation_user ON content_creation(user_id, created_at DESC);
```

**为什么需要这张表**:
- 用户的"创作历史"导航(以后想看上周做的小红书)
- 统计"哪种形态最常用 / 哪种风格最受欢迎",反向优化 LLM prompt
- 不存生成的具体内容(太大,且 LLM 可以重跑)

### 6.3 不引入新表的设计取舍

- 不存"主题聚类结果"(每次不同,存了无意义)
- 不存"生成的 9 张 PNG"(太大,文件路径在 `file_path` 就够了)
- 不存"HTML 动画"(同上)

---

## 七、付费与配额

| 用户档 | 体验 |
|---|---|
| **Free** | 每月 2 次创作(任一形态);只能"极客风" / "科普风" 预设 |
| **Pro** | 不限次数;全部风格预设;支持"自定义风格(粘贴示例)";可保存为模板 |

- 单次 run 配额: **3 quota** 基础 + **1 quota/形态**(小红书/博客/视频独立扣)
- 配额回滚:渲染失败(png 写不进去)回滚,LLM 失败不回滚(已耗 token)

---

## 八、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| `fetch_github_trending` Tool | 新增 | 小(API 已熟悉) |
| `fetch_weekly_data` Tool | 新增 | 小 |
| `cluster_and_pick_topics` Tool | 新增 | 小 |
| `generate_xiaohongshu_post` Tool + prompt | 新增 | 中(要迭代 prompt) |
| `generate_blog_markdown` Tool + prompt | 新增 | 中 |
| `generate_bilibili_script` Tool + prompt | 新增 | 中 |
| `render_xiaohongshu_images` (Core Graphics 模板) | 新增 | 中(模板设计 + 字体加载) |
| `render_bilibili_html_animation` (HTML 模板) | 新增 | 中(动画 CSS) |
| 创作向导 UI(形态选择 + 风格预设) | 新增 | 中 |
| 创作过程 UI(chat + 实时预览) | 扩展已有 | 中 |
| 9 张卡编辑 UI(单张重渲染) | 新增 | 中 |
| .zip 导出 | 新增 | 小 |
| 单测(LLM 输出 / 渲染 / 配额) | 新增 | 中 |
| i18n 词条(`creation.*`) | 新增 | 小 |
| `docs/工程进度/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: **大**。**这是 Starcat 现有 AI 功能之外最大的"内容工程"工作**。建议拆 3 个 Phase:
- Phase 1(2 周):博客 markdown(最容易)
- Phase 2(2 周):小红书图文(中等)
- Phase 3(2-3 周):B 站视频 HTML(最难,涉及动画 / 字幕)

---

## 九、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| LLM 生成的小红书文案不符合平台调性 | 中 | 收集 50+ 真实小红书爆款做 few-shot;用户可"自定义风格" |
| 9 张 PNG 视觉质量差,影响发布意愿 | **高** | 模板设计必须先做 A/B;v1.1 之前**只**做 1 套高质模板,不做模板选择 |
| 视频 HTML 动画过重,导出慢 | 中 | 单 HTML < 500KB;动画用 CSS 而非 JS;明确"v1 不支持导出 mp4,只导出 HTML" |
| 用户生成内容涉及版权(直接抄 README) | 中 | prompt 强调"基于事实 + 改写,不直接抄";生成后自动检测相似度,> 80% 警告 |
| 配额消耗失控(3 形态都试一遍) | 中 | run 开始时按所选形态预扣,切换形态不重复扣 |
| 平台规则变化(小红书 / B 站调 UI 规格) | 中 | 模板与渲染分离,平台规格变了改模板即可 |
| 用户发布到平台后被举报(AI 生成未标) | **高** | 输出强制带"AI 生成"水印(图右下角小字 + 配文末尾)+ 设置页有"显式标注"开关 |
| 视频脚本质量差(B 站用户嫌弃) | 中 | 与替代品推荐类似,prompt 需 50+ 真实 B 站科技视频脚本做 few-shot |

---

## 十、后续可拓展方向

1. **视频直接导出 mp4**:`AVFoundation` 把 HTML 录屏 → mp4(Phase 3 之后)
2. **多平台一键发布**:登录小红书 / B 站 API,自动上传(v1.1,需用户授权)
3. **互动数据回流**:发布后回传点赞 / 评论数,反哺 prompt 优化
4. **A/B 文案生成**:同一主题生成 3 版文案,让用户 A/B 测试
5. **品牌定制**:用户上传 logo / 配色,所有 PNG 模板自动应用
6. **数据可视化**:把 weekly stats 做成图表 PNG(用 Swift Charts 渲染)

---

## 十一、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿 | Claude |
