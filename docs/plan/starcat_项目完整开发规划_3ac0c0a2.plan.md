---
name: Starcat 项目完整开发规划
overview: 基于项目现有文档和市场调研，梳理 Starcat 的开发路线图、挑战分析、定价策略和 AI 功能实现方案。
todos:
  - id: plan-1
    content: 创建完整开发规划文档
    status: completed
  - id: plan-2
    content: 存储规划到 ICM 记忆
    status: pending
isProject: false
---

## Starcat 项目完整开发规划

---

### 一、项目定位回顾

Starcat = 面向重度 GitHub 用户的 Apple 平台 Star 管理与 AI 知识整理工具。核心价值是「整理、理解、找回、评估」，解决从「扁平收藏夹」到「可复用知识库」的问题。

---

### 二、技术架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                        Starcat App                          │
├─────────────┬─────────────┬─────────────┬──────────────────┤
│   SwiftUI   │   SwiftUI   │   SwiftUI   │     SwiftUI      │
│   macOS     │   iPhone    │   iPad      │     watchOS      │
│   (Tahoe)   │   (iOS 26)  │   (iPadOS)  │     (watchOS)   │
├─────────────┴─────────────┴─────────────┴──────────────────┤
│                    共享数据层 (GRDB/SQLite)                  │
├──────────────────────────┬──────────────────────────────────┤
│   CloudKit (用户数据同步)  │   Keychain (Token 存储)          │
├──────────────────────────┴──────────────────────────────────┤
│                    网络层 (URLSession)                      │
├────────────────────┬───────────────────────────────────────┤
│  GitHub REST API   │      自建 AI 代理服务（你的云服务器）    │
│  (Stars/Repo)      │  Gemini / DeepSeek / OpenAI 聚合        │
└────────────────────┴───────────────────────────────────────┘
```

### 二.1 UI 设计方向：Liquid Glass 风格

**macOS 26 (Tahoe) 引入了革命性的 Liquid Glass 设计语言**，Starcat 将全面采用这一最新设计方向，在视觉上与系统高度融合。

#### 核心设计原则

1. **Liquid Glass 材质**：半透明、毛玻璃、动态光影
2. **流畅动画**：spring 物理动画、matched transitions
3. **深度层次**：前景控件、玻璃层、背景层的三维空间感
4. **系统融合**：与 macOS 26 的透明菜单栏、Dock、Control Center 一致

#### 关键 SwiftUI API（macOS 26）

| API | 用途 |
|-----|------|
| `.glassEffect()` | 为任意 View 应用 Liquid Glass 材质 |
| `.glassEffectID()` + Namespace | 实现视图间的流畅变形动画 |
| `GlassEffectContainer` | 组合多个玻璃元素，优化渲染性能 |
| `.interpolatingSpring()` | 新的 spring 动画 API |
| `.matchedTransitionSource()` | 替代 matchedGeometryEffect |
| `.sidebarAdaptable` | 自适应侧边栏导航 |

#### 性能注意事项

- 使用 `.easeOut` 替代 `.spring()` 处理 hover 动画
- 避免直接动画化 shadow 参数（性能开销大）
- 优先暗色模式，减少透明层叠加计算
- 使用 `GlassEffectContainer` 优化重叠玻璃元素渲染

---

### 三、推荐的项目阶段划分

#### 阶段 1：基础版（10-14 周）

**目标**：一个可靠、精美的 GitHub Stars 管理器，采用 macOS 26 Liquid Glass 设计语言。

| 功能模块 | 工作量评估 | 说明 |
|---------|-----------|------|
| 项目搭建 + SwiftUI 入门 | 1 周 | AI 辅助学习 |
| GitHub OAuth 登录 | 1 周 | token 存 Keychain |
| Stars 同步（分页/增量） | 2 周 | 重点处理 rate limit |
| 本地 SQLite 缓存 | 1 周 | GRDB 封装 |
| macOS Liquid Glass UI | 3 周 | **重点：动画和流畅度** |
| 标签/语言/Untagged 视图 | 1 周 | 带计数的 sidebar |
| 搜索与过滤 | 1 周 | FTS5 全文搜索 |
| README Markdown 渲染 | 1 周 | WebView + GitHub 样式 |
| 笔记/状态管理 | 0.5 周 | 本地持久化 |
| JSON 导入导出 | 0.5 周 | OhMyStar/Astral 兼容 |
| 动效调优 + 细节打磨 | 2 周 | **重点：流畅度和交互动画** |

**UI/UX 重点**：
- 三栏布局采用 Liquid Glass 玻璃质感
- 列表滚动使用新的 scroll physics 和 snap-to-grid
- 页面切换使用 `.matchedTransitionSource` 实现 hero 动画
- 标签/按钮 hover 使用 `.easeOut` 动画（0.1-0.2s）
- 侧边栏使用 `.sidebarAdaptable` 自适应样式

#### 阶段 2：Apple 生态扩展（4-6 周）

- iPhone / iPad 适配（响应式布局）
- CloudKit 用户数据同步
- 快捷键、菜单栏、Spotlight 入口
- watchOS 轻量 companion

#### 阶段 3：AI Pro（6-10 周）

- 单仓库 AI 摘要
- AI 标签推荐（含确认流程）
- 批量未分类仓库整理
- **混合语义搜索（BM25 + Embedding + RRF）**
- **Release 订阅追踪**
- AI 项目健康度评估
- StoreKit 2 订阅接入

---

### 四、竞品分析：值得参考的功能

#### 4.1 GithubStarsManager（最值得参考）

**项目链接**：
- GitHub: https://github.com/AmintaCCCP/GithubStarsManager
- 官网: https://gsm.aminta.top/

**项目信息**：Electron + Go, 2957 stars, MIT 协议

**核心差异化功能**（值得 Starcat 借鉴）：

| 功能 | 说明 | Starcat 应如何借鉴 |
|------|------|-------------------|
| **AI Summaries & Categories** | 自动分析 README 生成摘要、标签、分类 | 直接采纳，作为核心 AI 功能 |
| **Semantic Search** | 混合搜索（BM25 + Embedding + RRF） | 采纳，混合搜索效果更好 |
| **Release Tracking** | 订阅仓库 release，一键下载资产 | **强烈建议加入**，差异化功能 |
| **Smart Asset Filters** | 按平台（macOS/Windows/Linux/ARM）过滤 | 加入，作为高级过滤能力 |
| **Bilingual Wiki Jump** | 中文项目跳转到 zread.me | 可作为中国区特色功能 |
| **14 Preset Categories** | 预设分类体系 | 采纳 + 自定义分类 |
| **AI Agents Integration** | v2.1.0 引入 AI Agent | 长期规划 |

**技术亮点**：
```
语义搜索实现（混合搜索）：
1. BM25 关键词检索
2. Gemini Embedding 向量检索
3. Reciprocal Rank Fusion (RRF) 融合
   score = 1/(k + rank_vector) + 1/(k + rank_bm25)
```

**AI 分析流程**：
```
1. 读取 README 内容（截断到关键段落）
2. 调用 LLM 生成：摘要、标签、支持平台
3. 生成向量 Embedding
4. 存入本地 SQLite
5. 搜索时：Embedding 相似度 + BM25 → RRF → Top-K
```

#### 4.2 其他竞品参考

| 竞品 | 链接 | 亮点 | Starcat 借鉴 |
|------|------|------|-------------|
| Starship | [App Store](https://apps.apple.com/us/app/starship-your-stars-on-github/id1530665887) | 嵌套标签、iCloud 同步 | 多端同步思路 |
| OhMyStar | [App Store](https://apps.apple.com/cn/app/ohmystar/id1218642292) | 功能完整、搜索强大 | 搜索体验、导入导出 |
| github-stars-organizer | [GitHub](https://github.com/davidnussio/github-stars-organizer) | Effect-TS、纯函数式 | 技术选型参考 |
| Starflare | [官网](https://starflare.app) | 轻量三栏、低门槛体验 | 简单体验设计 |
| Star Order | [官网](https://starorder.app) | 跨平台 SwiftUI | 技术选型参考 |

---

### 四.2 核心挑战与应对策略

#### 1. GitHub API Rate Limit

**挑战等级**：🔴 高

```
未认证：60 req/hour
OAuth：5,000 req/hour
```

**应对策略**：
- 实现分页队列，按优先级调度
- ETag/Last-Modified 缓存，避免重复请求
- README 懒加载，不在同步阶段全部拉取
- 增量同步策略：只拉 diff，不全量刷新
- 用户可配置同步频率和并发数

#### 2. AI 成本控制

**挑战等级**：🟡 中高

**成本参考**（以 1000 个 stars 首次处理为例）：

| 任务 | 模型选择 | 估算成本 |
|------|---------|---------|
| 单仓摘要 | Gemini 2.5 Flash | ~$0.05/仓 |
| 标签推荐 | Gemini 2.5 Flash | ~$0.02/仓 |
| Embedding（语义搜索）| text-embedding-3-small | ~$0.02/1000 仓 |
| 1000 仓全量处理 | - | ~$70（不含 embedding）|

**应对策略**：
- **BYOK 优先**：用户自带 API key，Starcat 不承担 AI 成本
- **Starcat Pro 订阅**：内置月度配额（如 500 次 AI 调用）
- **增量更新**：只对新增/变化的 repo 调用 AI
- **批量队列**：支持暂停、重试、跳过
- **Prompt 优化**：截断 README 至关键段落，减少 token 消耗

#### 3. 标签污染与 AI 准确性

**挑战等级**：🟡 中

**应对策略**：
- 所有 AI 标签输出必须经用户确认后才落库
- 支持「接受部分标签」
- AI 推荐标签与用户现有标签做相似度检测，避免同义标签
- 提供「撤销 AI 操作」入口

#### 4. 多端 CloudKit 同步

**挑战等级**：🟡 中

**数据分离原则**：
```
可重建数据（Repo 元数据、README）→ 本地 SQLite，各设备独立缓存
用户生成数据（Tags、Notes、Status）→ CloudKit 同步
```

**冲突策略**：基于时间戳合并，删除操作保留 tombstone

#### 5. 数据迁移

**挑战等级**：🟢 低（但重要）

- OhMyStar JSON 格式兼容
- Astral / Starship 导入
- JSON 导出（可被其他工具消费）

---

### 五、参考的 AI 开源项目

以下是 GitHub 上用于分析开源项目的活跃 AI 工具，Starcat 可以参考其思路或直接集成：

| 项目 | Stars | 核心能力 | 对 Starcat 的参考价值 |
|------|-------|---------|---------------------|
| [nanobot](https://github.com/HKUDS/nanobot) | 43k | 轻量 AI agent，本地记忆，MCP 工具 | 本地 RAG 方案参考 |
| [Understand-Anything](https://github.com/Lum1104/Understand-Anything) | 42k | 代码库 → 知识图谱，多 agent 管道 | 多 agent 协作思路 |
| [CodeCompass](https://github.com/negaga53/codecompass) | - | GitHub Copilot SDK，AST 解析，架构分析 | 结构化分析管线 |
| [RepoLens.AI](https://github.com/DARIO-engineer/RepoLens.AI) | - | Gemini 驱动，架构摘要、雷达图 | Web 分析界面参考 |
| [Kural](https://github.com/razyones/kural) | - | 7 维 embedding，结构健康度评分 | Embedding 方案参考 |
| [Reponova](https://github.com/CristianoCiuti/reponova) | - | MCP Server，多 repo 知识图谱 | MCP 工具设计参考 |

**Starcat AI 功能推荐实现路径**：
1. **BYOK 模式**：用户填写自己的 OpenAI/Anthropic/Gemini API key
2. **服务端代理**：Starcat 提供中转服务，聚合多个 provider
3. **本地 Ollama**：支持完全私有的本地模型（Qwen3 等）

---

### 六、App Store 上架准备清单

#### 必要条件

| 项目 | 说明 | 成本 |
|------|------|------|
| Apple Developer Program | $99/年（个人/公司） | $99/年 |
| Mac 设备或云构建 | 可用 CI/CD 云 Mac 降低初期投入 | 0-6000 元 |
| Xcode | 免费，App Store 下载 | 0 |
| App 图标和截图 | 建议 1024x1024 图标 + 各尺寸截图 | 自制或外包 |
| 隐私政策页面 | 必须托管 HTTPS 页面 | ~50 元/年 |
| 测试 Apple ID | 用于 TestFlight | 0 |

#### 上架流程

```
1. 注册 Apple Developer Program（1-3 天审批）
     ↓
2. 在 Xcode 创建 App ID 和证书
     ↓
3. 开发 + TestFlight 内部测试
     ↓
4. 准备 App Store 素材：
   - App 图标（1024x1024）
   - 截图（iPhone/iPad/macOS 各尺寸）
   - 描述文案（170 字符内）
   - 关键词（100 字符内）
   - 隐私政策 URL
     ↓
5. 提交审核（通常 1-3 天）
     ↓
6. 审核通过 → 上架
```

#### 中国区特殊考虑

- 如果面向国内用户：需要中国区 Apple Developer 账号（¥688/年）
- 隐私政策必须用中文
- AI 功能若涉及境外服务，需在隐私政策中说明

---

### 七、定价策略建议

#### 市场参考

| 竞品 | 定价 | 策略 |
|------|------|------|
| Starship | $1.99/年 或 $4.99 买断 | Pro 功能 = 无限标签 |
| OhMyStar | ¥7/月 或 ¥70/年 | Pro = 同步 + 去广告 |
| GITHUBSTAR | 多种套餐 | 按功能分级 |

#### Starcat 定价建议

```
┌─────────────────────────────────────────────────────────────┐
│                    免费版（功能完整）                        │
├─────────────────────────────────────────────────────────────┤
│ ✓ GitHub 登录与同步                                        │
│ ✓ 本地缓存和离线浏览                                        │
│ ✓ 基础 Repo 信息展示                                       │
│ ✓ README Markdown 渲染                                      │
│ ✓ 标签、分组、搜索、过滤                                    │
│ ✓ 笔记和状态管理                                           │
│ ✓ 基础导入导出                                             │
│ ✓ Liquid Glass 精美 UI                                     │
│ ✗ AI 语义搜索                                             │
│ ✗ AI 摘要和标签推荐                                        │
│ ✗ AI 每日推荐                                             │
│ ✗ AI 项目健康度评估                                        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                  Starcat Pro（订阅）                        │
├─────────────────────────────────────────────────────────────┤
│ 每月 $3.99 或 每年 $29.99（买断 $79.99）                   │
├─────────────────────────────────────────────────────────────┤
│ ✓ AI 语义搜索（自然语言查询）                               │
│ ✓ AI 单仓摘要（中文/英文）                                  │
│ ✓ AI 标签推荐 + 智能分类（14 个预设分类）                   │
│ ✓ AI 项目健康度评估                                        │
│ ✓ AI 批量整理（未分类仓库）                                 │
│ ✓ AI 每日推荐（个性化 GitHub Trending）                     │
│ ✓ **Release 订阅追踪** ← 差异化功能                        │
│ ✓ 月度 AI 调用配额（如 500 次）                             │
│ ✓ 调研报告生成（Markdown）                                  │
│ ✓ 高级导出（选型报告、Awesome List）                        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                  自建服务模式（免费）                        │
├─────────────────────────────────────────────────────────────┤
│ ✓ 使用你自己的云服务器作为 AI 代理                          │
│ ✓ 完全私有，数据不经过 Starcat 服务器                       │
│ ✓ 无 AI 调用次数限制                                       │
│ ✓ 支持 Gemini / DeepSeek / OpenAI                         │
└─────────────────────────────────────────────────────────────┘
```

#### 定价逻辑

1. **AI API 成本估算**（假设用户有 1000 个 stars）：
   - 全量 AI 摘要：约 $5（Gemini 2.5 Flash，便宜 10 倍）
   - Embedding 索引：约 $0.13（text-embedding-3-small）
   - 自建服务：服务器成本低，用户自己承担 API 费用

2. **定价高于竞品的原因**：
   - **Liquid Glass UI**：macOS 26 最新设计，视觉差异化
   - **AI 每日推荐**：竞品没有的独家功能
   - **自建服务支持**：满足技术用户的隐私需求

3. **买断 vs 订阅**：
   - 买断 $79.99 = 约 2.7 年订阅
   - 订阅 29.99/年 = 持续收入 + 服务端维护成本

4. **建议早期策略**：
   - 上架首年折扣（$19.99/年）
   - Pro 功能 14 天免费试用

---

### 八、AI 功能详细设计

#### 8.1 单仓库 AI 摘要（参考 GithubStarsManager 优化）

**参考 GithubStarsManager 的 AI 分析流程**：

```
用户点击 "AI 分析"
    ↓
读取：Repo 元数据 + README + Topics + 语言 + 用户备注
    ↓
截断 README 至关键段落（标题、安装、示例、API）
    ↓
调用 LLM 生成：
    ├── 一句话描述
    ├── 中文摘要
    ├── 提取标签（3-8 个）
    ├── 识别支持平台（macOS / Windows / Linux / iOS / Android）
    └── 分类到预设 Categories
    ↓
展示结果 + 用户确认后写入
```

**Prompt 示例（优化版）**：
```
你是一个专业的技术图书馆管理员。请分析这个 GitHub 仓库，生成结构化信息。

仓库信息：
- Name: {repo_name}
- Description: {description}
- Language: {language}
- Stars: {stars}
- Topics: {topics}
- README 内容：

{readme_content}

请用中文输出以下格式（JSON）：
{
  "one_liner": "一句话描述（不超过 20 字）",
  "summary": "2-3 句话的中文摘要",
  "tags": ["标签1", "标签2", "标签3"],
  "platforms": ["macOS", "iOS", "Linux"],  // 支持的平台
  "category": "14 个预设分类之一",
  "pros": ["优点1", "优点2"],
  "cons": ["缺点或注意事项1"],
  "min_example": "最小示例代码（如果有）"
}

只输出 JSON，不要有其他内容。
```

**预设分类体系（14 个，参考 GithubStarsManager）**：
```
AI/ML, Frontend, Backend, DevOps, Database, Security,
Mobile, Desktop, Library, CLI, Cloud, Data, Learning, Other
```

#### 8.2 AI 标签推荐 + 智能分类

**参考 GithubStarsManager 的 Smart Categorization**：

```
┌─────────────────────────────────────────────────────────┐
│                  AI 智能分类体系                         │
├─────────────────────────────────────────────────────────┤
│  预设 14 个分类（参考 GithubStarsManager）：              │
│  ├── AI/ML        - 人工智能、机器学习                 │
│  ├── Frontend      - 前端开发                         │
│  ├── Backend       - 后端开发                         │
│  ├── DevOps        - 运维、CI/CD、容器化              │
│  ├── Database      - 数据库、缓存、存储                 │
│  ├── Security      - 安全、加密、隐私                   │
│  ├── Mobile        - iOS、Android、跨平台             │
│  ├── Desktop       - 桌面应用                         │
│  ├── Library       - 开发库、SDK、框架                  │
│  ├── CLI           - 命令行工具                       │
│  ├── Cloud         - 云服务、Serverless                │
│  ├── Data          - 数据处理、分析、可视化              │
│  ├── Learning      - 学习资源、教程、文档               │
│  └── Other         - 其他                             │
│                                                         │
│  支持自定义分类（Pro 功能）                             │
└─────────────────────────────────────────────────────────┘
```

**设计原则**：**必须用户确认，标签才落库**

**流程**：
```
用户点击 "AI 推荐标签"
    ↓
分析：README + Topics + Description + Language
    ↓
输出：3-8 个推荐标签（带置信度）
    ↓
展示标签列表 + 选择性确认
    ↓
用户勾选要应用的标签 + 确认
    ↓
写入本地数据库
```

**同义标签检测**：
```
检测到推荐标签 "LLM" 
    ↓
对比用户现有标签：[大模型, LLM, 语言模型]
    ↓
提示：「LLM」与现有标签「大模型」「语言模型」相似，是否合并？
    ↓
用户选择：合并 / 分别保留 / 忽略推荐
```

#### 8.3 语义搜索（混合搜索方案）

**技术方案**：混合搜索 = BM25 关键词 + 向量Embedding + RRF 融合

```
┌─────────────────────────────────────────────────────────┐
│                    混合搜索架构                          │
├─────────────────────────────────────────────────────────┤
│  1. 索引构建（离线）                                    │
│     ├── BM25：分词 → 倒排索引 → 得分                   │
│     └── Embedding：README → text-embedding → 向量存储     │
│                                                         │
│  2. 查询阶段                                            │
│     ├── BM25 检索：query 分词 → Top-K                  │
│     ├── 向量检索：query embedding → 余弦相似度 Top-K    │
│     └── RRF 融合：得分 = 1/(k+rank_v) + 1/(k+rank_b)  │
│                                                         │
│  3. 结果优化                                            │
│     ├── 过滤：语言 + 更新时间 + 非 archived              │
│     └── LLM 总结：解释命中原因                          │
└─────────────────────────────────────────────────────────┘
```

**参考 GithubStarsManager 的 RRF 实现**：

```python
# RRF (Reciprocal Rank Fusion) 公式
k = 60  # 调参常量
rrf_score = 1.0 / (k + vector_rank) + 1.0 / (k + bm25_rank)
```

**优势**：
- BM25：精确关键词匹配
- 向量：语义理解能力
- RRF 融合：兼顾两种检索优点

**存储方案**：
- SQLite + GRDB（Swift 友好）
- 向量存储：pgvector 或 SQLite 向量扩展
- 或云服务器端处理向量（利用你的服务器）

**查询示例**：
```
用户输入："找适合做生产环境 API 的 Python 框架，要最近还在维护的"

系统：
1. BM25 检索：匹配 "Python API framework production" → Top 20
2. 向量检索：语义相似 → Top 20
3. RRF 融合：两种检索结果加权排序
4. 过滤：Python + 最近更新 + 非 archived
5. LLM 总结：
   "根据您的需求，推荐以下仓库：
   1. FastAPI - 现代 Python Web 框架，适合生产 API...
   2. Django - 全栈框架...
   命中原因：FastAPI README 提到'production-ready'，
   是目前最流行的 Python API 框架"
```

#### 8.4 Release 订阅追踪（差异化功能）

**参考 GithubStarsManager，这个功能值得加入**：

```
┌─────────────────────────────────────────────────────────┐
│                  Release 订阅追踪                         │
├─────────────────────────────────────────────────────────┤
│  订阅仓库的 Release 更新，统一时间线展示                   │
│                                                         │
│  功能列表：                                             │
│  ├── 订阅/取消订阅 Release                              │
│  ├── 时间线视图（最新发布在前）                         │
│  ├── 已读/未读状态管理                                  │
│  ├── 智能资产过滤                                       │
│  │   ├── 平台：macOS / Windows / Linux / ARM          │
│  │   └── 类型：dmg / zip / deb / rpm / apk            │
│  ├── 一键复制下载链接                                   │
│  └── 直接下载（可选）                                   │
└─────────────────────────────────────────────────────────┘
```

**技术实现**：
```
1. GitHub API: GET /repos/{owner}/{repo}/releases
2. 本地缓存：存储 release 历史记录
3. 增量检查：对比 last_fetch 时间
4. 通知：macOS Notification Center
```

**UI 设计**：
- 独立 Tab：Release Timeline
- 按仓库分组 or 时间线混合展示
- 每条 Release 显示：版本号、发布名称、发布时间、资产列表

---

#### 8.5 AI 服务商自定义

**支持列表**：
| Provider | 模型 | 适用场景 | 成本 |
|----------|------|---------|------|
| OpenAI | GPT-4o, GPT-4o-mini | 综合能力强 | 中 |
| Anthropic | Claude Sonnet 4.6 | 长上下文 | 中高 |
| Google | Gemini 2.5 Flash | 性价比最高 | 低 |
| Ollama | Qwen3, Llama3 | 完全私有 | 几乎为 0 |
| Groq | Llama3 | 低延迟 | 低 |
| DeepSeek | V4 Flash | 中文强 | 低 |

**配置界面**：
```
设置 → AI 配置
├── 使用 Starcat Pro（内置配额）
├── 使用自己的 API Key
│   ├── Provider: [下拉选择]
│   ├── API Key: [安全输入]
│   └── 默认模型: [下拉选择]
└── 使用本地 Ollama
    ├── Endpoint: http://localhost:11434
    └── 模型: [自动检测]
```

---

### 九、全 AI 开发时间估算

#### 条件假设

- **全 AI 开发**：Cursor / Claude Code 为主力，你做产品决策和验收
- **零 Swift 经验**：需要 AI 辅助学习 + 边做边学
- **注重 UI/UX**：Liquid Glass 设计和动画调优需要更多时间
- **有后端经验**：AI 代理服务你自己可以搞定

#### 阶段 1：基础版（非 AI 部分）

| 任务 | AI 辅助工时 | 实际日历时间 |
|------|------------|-------------|
| SwiftUI 入门（边做边学） | - | 2 周 |
| 项目搭建 + GitHub OAuth | 3-5 天 | 1 周 |
| Stars 同步 + SQLite | 3-5 天 | 1.5 周 |
| macOS Liquid Glass UI | 1 周 | **3 周** |
| 动效调优 + 细节打磨 | - | **2 周** |
| 搜索 + 过滤 + README | 3-5 天 | 1.5 周 |
| 标签/笔记/导入导出 | 3-5 天 | 1 周 |

**阶段 1 估算**：总计约 **10-14 周**（含 UI/UX 打磨）

#### AI 代理服务（你的云服务器）

| 任务 | 时间 | 说明 |
|------|------|------|
| AI 代理服务开发 | 1-2 周 | 你有后端经验 |
| Gemini API 集成 | 3-5 天 | 国内访问相对稳定 |
| Quota + 缓存 | 1 周 | Redis 缓存层 |

#### 阶段 3：AI 功能

| 任务 | AI 辅助工时 | 说明 |
|------|------------|------|
| 单仓摘要 | 3-5 天 | Prompt 工程是关键 |
| AI 标签推荐 + 确认流 | 1 周 | 需设计 UI |
| 语义搜索 + Embedding | 2-3 周 | 向量存储选型 |
| AI 每日推荐 | 2 周 | Trending 数据 + 推荐算法 |
| 订阅系统接入 | 1 周 | StoreKit 2 |

**阶段 3 估算**：总计约 **6-8 周**

#### 全流程估算

```
基础版 + UI/UX 打磨：10-14 周
AI 代理服务：2-3 周（与你并行）
AI 功能：6-8 周
测试 + 调优：4 周
App Store 审核：1-2 周

总计（全 AI 开发）：约 5-7 个月
```

#### 关键时间点

| 里程碑 | 预计时间 |
|--------|---------|
| MVP（基础管理功能） | 3-4 个月 |
| Alpha（可用的 AI 功能） | 5-6 个月 |
| App Store 上架 | 6-7 个月 |

---

### 十、AI 每日推荐 + Trending Discovery（已确认加入计划）

#### 功能定位

将 Starcat 从「个人图书馆」升级为「技术情报站」，让用户每天都有理由打开应用。

#### 功能设计（参考 GithubStarsManager 的 Trending Discovery）

```
┌─────────────────────────────────────────────────────────┐
│                    发现页 / Explore                      │
├─────────────────────────────────────────────────────────┤
│  [今日精选] [上升最快] [新晋项目] [为你推荐]               │
├─────────────────────────────────────────────────────────┤
│  今日精选：基于你的技术栈和使用场景的 AI 个性化推荐         │
│                                                         │
│  上升最快：过去 24h/7d star 增长最快的项目                │
│           （排除 bot 刷星项目）                          │
│                                                         │
│  新晋项目：过去 7 天内创建且获得 100+ stars 的项目        │
│                                                         │
│  为你推荐：结合你的收藏偏好 + GitHub trending             │
└─────────────────────────────────────────────────────────┘
```

**参考 GithubStarsManager 的 Trending 功能**：
- 按时间范围浏览：日榜、周榜、月榜
- AI 驱动的项目摘要
- 一键订阅（添加到你的 stars）

#### AI 评分算法

| 维度 | 权重 | 说明 |
|------|------|------|
| Star 增长率 | 30% | 过去 7 天 vs 过去 30 天 |
| 活跃度 | 20% | 最近 commit、issue 响应、PR merge |
| 维护状态 | 20% | 无 archived、fork ratio 正常 |
| 与用户兴趣匹配 | 20% | 基于已收藏项目的 language/topic |
| 质量信号 | 10% | README 完整性、license、release |

#### 数据来源

- GitHub Search API：`sort=stars&order=desc` + 时间范围过滤
- GitHub Trending 页面
- 第三方聚合 API：ossInsight.io、gitlog.io
- 缓存策略：每日更新一次，避免频繁调用

#### 与现有功能的关联

```
发现页推荐项目
    ↓
点击「收藏」→ 自动同步到你的 Stars
    ↓
进入你的图书馆 → 享受 AI 整理服务
```

#### 实现优先级

建议作为 **P1 功能**（MVP 之后的第一个迭代点），因为：
- 提供每日打开理由，提升留存
- 为 AI Pro 订阅提供高频使用场景
- 与现有「收藏管理」形成闭环

---

### 十一、未来探索方向（已记录，待定）

#### 自媒体内容生成工具

**核心思路**：帮助技术博主/内容创作者快速生成项目推荐内容。

**潜在场景**：
- 发现优质项目 → AI 分析 → 生成多平台内容
- 视频脚本生成（B站、YouTube）
- 技术文章生成（公众号、博客）
- 简报/周刊自动生成

**当前状态**：**待定**，尚未形成具体产品方案。

**后续动作**：
- 验证目标用户（技术博主）是否有强需求
- 调研竞品（如有）的内容生成能力
- 确认变现路径

---

### 十三、UI/UX 详细设计规范

#### 13.1 三栏布局设计

```
┌────────────────────────────────────────────────────────────────────┐
│  Liquid Glass 菜单栏 (macOS 26 透明样式)                            │
├──────────────┬─────────────────────────────────┬───────────────────┤
│              │                                 │                   │
│   Sidebar    │        Repo List               │     Detail        │
│   (220pt)    │        (弹性宽度)               │     (380pt)      │
│              │                                 │                   │
│  ┌────────┐  │  ┌─────────────────────────┐   │  ┌─────────────┐  │
│  │ Avatar │  │  │ 🔍 搜索框 (Glass 样式) │   │  │  Repo 标题  │  │
│  └────────┘  │  └─────────────────────────┘   │  │             │  │
│              │                                 │  │  Tabs:      │  │
│  All Repos   │  ┌─────────────────────────┐   │  │  README     │  │
│  ★ 1,234     │  │ 🟢 repo-name           │   │  │  Details    │  │
│              │  │    description...       │   │  │  Notes      │  │
│  Untagged    │  │    Python • 12.3k ★    │   │  │             │  │
│  📂 234      │  └─────────────────────────┘   │  └─────────────┘  │
│              │                                 │                   │
│  Tags ────   │  ┌─────────────────────────┐   │                   │
│  ├─ AI       │  │ 🔵 another-repo         │   │                   │
│  ├─ macOS    │  │    ...                  │   │                   │
│  └─ Python   │  └─────────────────────────┘   │                   │
│              │                                 │                   │
│  Languages ─ │                                 │                   │
│  ├─ Swift    │         (滚动区域)              │                   │
│  └─ Go       │                                 │                   │
│              │                                 │                   │
└──────────────┴─────────────────────────────────┴───────────────────┘
```

#### 13.2 Liquid Glass 组件规范

**玻璃容器样式**：
```swift
// 标准玻璃容器
.glassEffect(Glass.regular, in: RoundedRectangle(cornerRadius: 12))

// 突出的玻璃按钮
.buttonStyle(.glassProminent)

// 玻璃输入框
TextField(...)
    .textFieldStyle(.glass)
```

**颜色系统**：
| 用途 | 颜色 | 说明 |
|------|------|------|
| 主色调 | System Blue | 强调色 |
| 成功 | System Green | 活跃项目 |
| 警告 | System Orange | 待处理 |
| 背景 | Dynamic（系统）| 自动适配深/浅色 |
| 文字 Primary | Dynamic Label | 系统语义色 |
| 文字 Secondary | Dynamic Secondary Label | 系统语义色 |

#### 13.3 动画规范

**滚动和列表**：
```swift
// 使用新的 snap-to-grid
ScrollView {
    LazyVStack {
        ForEach(repos) { repo in
            RepoRow(repo: repo)
                .scrollTargetLayout()
        }
    }
}
.animation(.interpolatingSpring(duration: 0.4, bounce: 0.2), value: selectedRepo)
```

**页面切换**：
```swift
// Hero 动画（使用 matchedTransitionSource）
NavigationLink(value: repo) {
    RepoRow(repo: repo)
}
.matchedTransitionSource(id: repo.id, in: namespace)
```

**Hover 效果**：
```swift
// 推荐使用 easeOut，避免使用 spring
Button {
    // action
} label: {
    Text("Label")
}
.buttonStyle(.easeOut(duration: 0.15))
```

**列表项展开**：
```swift
// 玻璃变形动画
.glassEffectID(repo.id, in: namespace)
```

#### 13.4 性能优化策略

1. **分层渲染**：
   - 背景层：静态或低频更新
   - 玻璃层：使用 `GlassEffectContainer` 组合
   - 前景层：动态交互元素

2. **动画优化**：
   - Hover 动画用 `.easeOut(duration: 0.1-0.2)`
   - 避免直接动画化 shadow
   - 优先动画 opacity、scale、offset

3. **列表优化**：
   - 使用 `LazyVStack` 懒加载
   - 图片异步加载 + 缓存
   - README WebView 按需渲染

#### 13.5 交互细节

**侧边栏交互**：
- 选中态：背景高亮 + 左边框强调
- Hover：轻微放大（scale: 1.02）+ 透明度变化
- 拖拽排序：玻璃变形动画

**列表项交互**：
- 点击：scale down → scale up 弹性效果
- 选中：背景渐变 + 边框高亮
- 右键菜单：玻璃弹出层

**详情页 Tab 切换**：
- 使用 `.matchedTransitionSource` 实现平滑过渡
- Tab indicator 使用 spring 动画跟随
- 内容切换使用 crossfade（0.25s）

### 十四、你的情况对应的调整

| 你的情况 | 规划调整 |
|---------|---------|
| 全 AI 开发，无 Swift 经验 | 规划时间已含 2 周 Swift 学习期 |
| 注重 UI 流畅度和动画 | 规划中增加了 UI 打磨时间（+2 周）|
| 有后端和运维经验 | AI 代理服务你自己开发，省去这部分时间 |
| 有云服务器 | 可作为 AI 代理层，降低 AI 成本 |
| 面向全球市场 | 英文 UI + 隐私合规 |

**推荐技术栈（针对你的情况）**：

| 层级 | 选择 | 说明 |
|------|------|------|
| 客户端 | SwiftUI + macOS 26 | Liquid Glass 最新设计 |
| 本地数据库 | GRDB.swift | SQLite 封装 |
| AI 调用 | 调你的云服务器 | 不内置 API key |
| 服务端 | 你熟悉的语言 | Go/Node.js/Python |
| AI Provider | Gemini（首选）| 国内访问相对稳定 |
| 缓存 | Redis | AI 结果缓存 |

### 十五、下一步行动建议

#### 立即可执行事项

1. **注册 Apple Developer Program**
   - $99/年，面向全球市场
   - 审批时间：1-3 天

2. **准备云服务器环境**
   - 部署 AI 代理服务（可用 Docker）
   - 配置域名（可选）

3. **AI 开发启动**
   - 选择服务端语言（推荐 Go 或 Node.js）
   - 集成 Gemini API
   - 实现基础的 AI 代理 + Quota 逻辑

4. **SwiftUI 学习（与 AI 代理并行）**
   - 使用 Cursor AI 辅助学习
   - 跟随官方 SwiftUI 教程

5. **项目代码生成**
   - 使用 Cursor AI 生成基础框架
   - 重点打磨 UI 和动画部分

#### 技术债务预警

- GitHub API 限流策略必须在一开始设计好
- SQLite 缓存 Schema 设计要考虑后续扩展
- Liquid Glass 动画性能需要真机测试
- AI 代理服务需要处理 Rate Limit 和错误重试

#### 建议的 MVP 功能优先级

```
P0（必须有）：
1. GitHub OAuth + Stars 同步
2. Liquid Glass 三栏布局（Sidebar/RepoList/Detail）
3. 标签管理和视图
4. 搜索和过滤
5. README 渲染
6. 流畅的交互动画

P1（第一版 AI）：
1. AI 代理服务（你的云服务器）
2. 单仓 AI 摘要
3. AI 标签推荐（带确认）
4. 自然语言搜索（简化版）
5. AI 每日推荐

P2（后续迭代）：
1. CloudKit 同步
2. iPhone/iPad 适配
3. 订阅系统
4. 项目健康度评估
5. AI 周报
```
