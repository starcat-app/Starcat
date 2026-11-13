# 详细设计

> 本目录包含 Starcat 项目的详细技术设计文档。
>
> 阅读规则更新（2026-11-12）：这里同时保留当前契约、历史设计、实施记录和未实施方案。先读各文档顶部的日期、状态与替代关系，再核对源码及关联验收记录；标题中的“正式”“最终”不等于当前实现。下表补齐本目录现有文档，原有重复编号暂不改名。

---

## 文档索引

| 编号 | 文档 | 内容 |
|------|------|------|
| 00 | [提示词设计](00-提示词设计.md) | 早期 AI Prompt 设计；实际任务配置以当前调用链为准 |
| 01 | [数据库设计](01-数据库设计.md) | GRDB Schema、表结构、FTS5、索引优化 |
| 02 | [性能优化设计](02-性能优化设计.md) | 列表优化、README 缓存、内存优化 |
| 03 | [项目结构设计](03-项目结构设计.md) | 目录结构、模块划分、命名规范 |
| 04 | [技术选型](04-技术选型.md) | 依赖库、平台兼容性、第三方服务 |
| 05 | [GitHub API 设计](05-GitHub%20API设计.md) | OAuth、端点、Rate Limit、同步策略 |
| 06 | [核心模块设计](06-核心模块设计.md) | SyncManager、AI 服务、Keychain、日志 |
| 07 | [Trending 数据本地缓存设计](07-Trending数据本地缓存设计.md) | 缓存演进背景；现行 TTL 与多级缓存见 31 |
| 07 | [UI 交互设计](07-UI交互设计.md) | 焦点管理、按钮规范、Popover 交互 |
| 08 | [设置页面设计](08-设置页面设计.md) | 设置窗口、Tab 布局、偏好项设计 |
| 09 | [关于页面设计](09-关于页面设计.md) | 独立关于窗口、分段页面、致谢页面 |
| 10 | [国际化(i18n)设计](10-国际化(i18n)设计.md) | String Catalog、SwiftUI 本地化、多语言扩展 |
| 11 | [Phase 2 AI 与 Release 详细设计](11-Phase2-AI与Release详细设计.md) | 早期 AI / Release 阶段设计，不直接作为当前待办 |
| 12 | [AI 库选型调研](12-AI库选型调研.md) | 选型背景；当前依赖由工程配置和受控锁文件确定 |
| 13 | [智能搜索栏交互设计](13-智能搜索栏交互设计.md) | 右上角快速搜索、Pro / AI 搜索预留、toolbar 交互 |
| 14 | [AI 集成落地记录](14-AI集成落地记录.md) | 早期集成过程及当时验证，不替代当前 Provider 契约 |
| 15 | [AI 设置与调用链重构方案](15-AI设置与调用链重构方案.md) | 多服务商 BYOK、任务模型选择、参数、Prompt、流式摘要 |
| 16 | [活动页设计](16-活动页设计.md) | Activity 聚合页、Release / Events / 本地推荐、三栏接入 |
| 17 | [项目健康度与维护活跃度设计](17-项目健康度与维护活跃度设计.md) | 规则评分 + AI 解释、Community Profile / Stats / Advisories 缓存、Insights UI、License 风险分类 |
| 18 | [三场景共用架构](18-三场景共用架构.md) | Manage / Trending / Weekly / Activity 4 场景的 UI 骨架 + 行为契约共用架构（R-01 v1.2~v2.0） |
| 19 | [wiki 集成](19-wiki集成.md) | 外部文档站与 Zread 的早期设计演进，客户端现状见 20 |
| 20 | [starcat-wiki-api 客户端对接](20-wiki-api-对接.md) | 当前单仓查询、客户端磁盘缓存与知识库后台补齐；保留首期实施记录 |
| 21 | [weekly-api 后端 3 源聚合改造](21-weekly-api-后端3源聚合改造.md) | R-04：把 weekly / zread / discovery 3 表 3 端点重构为主表 `github_repos` + 4 附表 + 1 聚合接口 `/api/v1/repos`，gh_repo_id 主键 |
| 22 | [weekly 客户端 3 源聚合对接](22-weekly-客户端3源聚合对接.md) | R-04 配套客户端方案：列表换 3 源合并 feed、列表 repo name / 详情 full_name 同行展示来源标识，客户端只展示和筛选不参与聚合 |
| 23 | [Chrome 插件方案](23-Chrome-插件方案.md) | Starcat Companion Chrome 插件总体方案 v1.0：URL Scheme + 本地 HTTP 双向通信、5 项 MVP（状态胶囊 / 一键采集 / 笔记追加 / 浮按钮 / 角标）、与 R-04 主表 `source=clip` 接入 |
| 24 | [GitHub 搜索集成设计](24-GitHub-搜索集成设计.md) | 系统级 / 工具级 GitHub 搜索集成方案 |
| 25 | [Show HN 发现源设计](25-Show-HN发现源设计.md) | 历史独立入口方案，已由 Weekly 多来源方案替代，不恢复 Activity 待办 |
| 26 | [向量搜索改进](26-向量搜索改进.md) | 结构化索引快照、README 清洗与差异重建的实施记录 |
| 27 | [RepoContextPacker 设计](27-RepoContextPacker设计.md) | 已存在的 Swift 上下文打包管道及历史接入清单 |
| 28 | [搜索增强最终方案](28-搜索增强最终方案.md) | 保留 Manage 快速过滤，新增 `⌘K` 全局搜索中心，聚合 Local / GitHub / AnySearch Web 并复用现有详情与动作体系 |
| 29 | [关键词与全文检索设计](29-关键词与全文检索设计.md) | 双引擎落地实现：FTS5（repos_fts unicode61 + notes_fts trigram + BM25 排序）+ 向量语义（A 显示重标定 + B 字面 boost + C FTS hit 加权 + tier 1-4★）+ 示例走查 + 后期优化方向 |
| 30 | [本地 RAG 设计](30-本地RAG设计.md) | 知识库 RAG 详细设计：默认只使用 `libraryState == .inLibrary` repo，新增 chunk-level RAG 索引、知识库问答工作台、citation chip 与 evidence inspector |
| 31 | [Trending / Weekly 多级缓存改造](31-Trending-Weekly缓存改造.md) | R-06 完整记录：客户端 SQLite TTL（Trending 分桶 1h/6h/24h、Weekly 6h）+ 后端同窗口内存缓存（ETag / pre-gzip / bulk endpoint）+ Weekly 渐进式 SWR 双轨制（dataSource .local/.remote） |
| 32 | [Manage 列表分页与首页边沿上屏](32-Manage列表分页与首页边沿上屏.md) | Manage 列表分页、首页边沿上屏与滚动体验调整 |
| 33 | [OpenSSF Scorecard 安全评分设计](33-OpenSSF-Scorecard-安全评分设计.md) | 已 star 仓库 OpenSSF Scorecard 缓存、列表 full_name 行徽章、详情页雷达图、后台刷新、i18n 与测试边界 |
| 34 | [StarcatCLI 与外部 MCP 桥接设计](34-StarcatCLI与外部MCP桥接设计.md) | stdio MCP adapter + CLI 入口,解决 Codex / 老式 client 不兼容 HTTP MCP 的兼容性问题 |
| 35 | [GitHub Stars List 分组设计](35-GitHub-Stars-List分组设计.md) | GitHub Stars List 分组侧边栏入口 + OAuth 组织限制处理 |
| 36 | [CodebaseMemory 集成设计](36-CodebaseMemory集成设计.md) | App Store 内嵌、Direct 外部安装的渠道分流，二进制解析、索引与图谱接入 |
| 37 | [AI 用量统计面板设计](37-AI用量统计面板设计.md) | 用量采集、统计与设置面板 |
| 37 | [外部搜索服务设计](37-外部搜索服务设计.md) | External Search Provider 抽象、设置页、SearchCenter Provider View、External Context 单 Provider / Pro 聚合与缓存策略 |
| 37 | [探索发现与榜单详细设计](37-探索发现与榜单详细设计.md) | Discovery 数据、榜单与客户端探索入口 |
| 38 | [Starred 与知识库改造详细设计](38-Starred与知识库改造详细设计.md) | 已实现的知识库状态与持久化，保留改造前边界 |
| 39 | [全局语言与列表控制详细设计](39-全局语言与列表控制详细设计.md) | Explore Weekly 入口、全局语言与列表控制 |
| 40 | [支付对接详细设计](40-支付对接详细设计.md) | App Store / Direct 支付与授权边界 |
| 41 | [分发渠道详细设计](41-分发渠道详细设计.md) | 两渠道构建、分发和更新能力 |
| 42 | [Weekly 多来源采集与置顶](42-Weekly多来源采集与置顶.md) | 固定来源目录、持久化 enrich 队列、HelloGitHub 回填、AI 情报 Skill、动态来源缓存与多项目置顶的落地契约 |
| 45 | [后端服务版本注入与 Ping 契约](45-后端服务版本注入与Ping契约.md) | 六服务本地版本注入与 ping 代码已存在；生产版本需独立核对 |
| 46 | [快捷键与应用命令设计](46-快捷键与应用命令设计.md) | Stars 同步、RAG 工作台与当前仓库 AI 的快捷键、上下文命令路由、冲突校验和设置页归属 |
| 47 | [AI 个人笔记生成详细设计](47-AI个人笔记生成详细设计.md) | 私有笔记生成、上下文与用户确认边界 |
| 48 | [多语言现状与原 18 语言设计](48-18种语言本地化扩展详细设计.md) | 当前配置为 17 种语言；18 语言与 RTL 章节保留为历史设计 |
| 49 | [洞察中心详细设计](49-洞察中心详细设计.md) | 已实现：我的洞察、仓库洞察、v16 缓存、结构化下钻、GitHub 活动与 Star 趋势；外部授权门槛单列 |
| 50 | [仓库星标历史整体落地方案](50-仓库星标历史整体落地方案.md) | 保留 v1.3 历史，当前 History 服务与数据链路见 62 / 66 |
| 51 | [我的项目整体落地方案](51-我的项目整体落地方案.md) | 星标模块下的个人 / 组织 / Private 项目分类、GitHub App 只读授权、v17 关系表、同步、详情复用与隐私边界 |
| 52 | [Alfred 外部搜索集成详细设计](52-Alfred外部搜索集成详细设计.md) | Starcat Pro 外部集成：复用 CLI/MCP 全局搜索、跨来源去重、owner avatar 缓存、Deep Link / GitHub 打开与三仓库实施验收契约 |
| 53 | [uTools 与 Raycast 外部搜索集成详细设计](53-uTools与Raycast外部搜索集成详细设计.md) | 复用 `starcat search` 公共契约，定义 uTools list 插件、Raycast Extension、头像差异、取消机制、独立仓库与发布验收 |
| 54 | [Starcat 外部应用插件化集成扩展初步方案](54-Starcat外部应用插件化集成扩展初步方案.md) | 在 Alfred、uTools、Raycast 之外，规划 Spotlight、Shortcuts、LaunchBar、VS Code、PopClip、Obsidian、JetBrains 与 MCP Host 的分层接入和实施优先级 |
| 55 | [Starcat macOS 桌面小组件初步方案](55-macOS桌面小组件初步方案.md) | Focus、今日重逢、Release Watch 等 WidgetKit 组件，以及 App Group 快照、头像、Deep Link、隐私、刷新和 Store / Direct 双渠道边界 |
| 56 | [macOS 桌面小组件详细落地方案](56-macOS桌面小组件详细落地方案.md) | 已有实现与历史方案；2026-10-07 取消剩余工作，不恢复旧验收待办 |
| 57 | [Agent 工作台与统一能力层详细设计](57-Agent工作台与统一能力层详细设计.md) | Agent 当前权威方案：过程/结果双层 Run Surface、RAG Composer/证据链复用、Agent 与 MCP 统一能力、v19 迁移和分阶段发布门禁 |
| 58 | [DeepSeek Harness 集成评估与 POC 技术方案](58-DeepSeekHarness集成评估与POC技术方案.md) | 单后端评估历史，公共多后端底座见 59；旧版本不代表当前安装版本 |
| 59 | [External Agent Runtime 多后端 POC](59-ExternalAgentRuntime多后端POC技术方案.md) | 多后端适配与只读工具桥，产品化验收另见 63 |
| 60 | [Starcat 数据贡献与数据平台详细设计](60-Starcat数据贡献与数据平台详细设计.md) | 历史总设计，当前公开 Star 贡献见 63，History 见 62 / 66 |
| 61 | [Starcat 自研仓库推荐系统详细设计](61-Starcat自研仓库推荐系统详细设计.md) | 独立 Trainer/API、时间衰减 co-star、Metric Learning、内容冷启动、动态融合、评估与 SimRepo 迁移 |
| 62 | [Starcat 自研星标历史服务详细设计](62-Starcat自研星标历史服务详细设计.md) | 独立 History 服务、WatchEvent 日聚合与查询口径，不启用旧用户 History 贡献方案 |
| 63 | [Agent Runtime 执行过程产品化](63-AgentRuntime执行过程产品化专项.md) | 三种 Runtime 事件与工作台呈现；真实任务人工验收边界单列 |
| 63 | [公开 Star 贡献与 Collection 服务](63-Starcat公开Star数据静默上报与Collection服务详细设计.md) | 用户主动开启后的公开 Star 快照贡献、Collection 与 Recommend v2 链路 |
| 64 | [ACP 协议接入评估与暂缓方案](64-ACP协议接入评估与暂缓方案.md) | ACP 协议边界、RAG / Agent 双路径候选架构、现有适配器不迁移决策与重新评估门禁 |
| 65 | [Agent Runtime、RAG 与 AI 服务统一路由方案](65-AgentRuntime与AI服务统一路由方案.md) | 已认可但待明确开干的统一路由方案，不作为当前已实现架构 |
| 66 | [本地数据湖与云端 Serving 同步](66-Starcat本地数据湖与云端Serving同步详细设计.md) | 本地 Raw、History 增量、Recommend 模型产物与同步边界 |
| 67 | [数据平台 Web 运维控制台](67-Starcat数据平台Web运维控制台详细设计.md) | 已有数据平台页面、BFF 与任务基础；完整目标和运行验收分别核对 |
| 68 | [Anthropic Messages API 服务商详细设计](68-Anthropic服务商详细设计.md) | 新增 `.anthropic` adapter：Messages API、tool_use 内部转换、不改业务消息模型；Embedding 门禁关闭 |
| 69 | [从 CC Switch 导入 AI Provider 详细设计](69-CC-Switch导入Provider详细设计.md) | 从 `~/.cc-switch/cc-switch.db` 一次性导入 BYOK；永远新增 `cc-switch:` 前缀；Direct 探测 / App Store 选择器 |
| 70 | [Linux.do 项目发现与来源标识接入方案](70-Linux.do项目发现与来源标识接入方案.md) | 客户端 API、来源索引与缓存已存在；采集与生产状态分开记录 |
| 71 | [关注关系图谱技术方案](71-关注关系图谱技术方案.md) | 已实现的 2D Following / Followers 双向图谱；3D 章节为历史探索 |
| 补充 | [设置页文案重写清单](2026-06-15-设置页文案重写清单.md) | 旧六 Tab 阶段的文案讨论，不代表当前设置页结构 |
| 补充 | [README 渲染设计](readme.md-渲染设计.md) | GitHub HTML、ETag 缓存与 WebView 的设计背景 |
| 补充 | [健康度评分设计](健康度评分设计.md) | 健康评分数据流与关系图，配合 17 阅读 |
| 补充 | [每周 AI 大事 MVP 实现说明](每周AI大事-MVP实现说明.md) | 已被正式链路替代的历史 MVP，不执行旧演示命令 |
| 补充 | [每周 AI 大事正式链路](每周AI大事-正式链路设计与验收.md) | 正式内容、聚合服务、客户端与阶段验收记录 |
| 补充 | [每日热点 API 契约](每日热点-API契约.md) | 报告身份、目录 / 内容 revision 与批次写入契约 |
| 补充 | [编程语言图标](编程语言图标.md) | 本地 Devicon、语言颜色及 fallback 策略 |

---

## 快速导航

### 数据库相关
- [数据库设计](01-数据库设计.md) - 表结构、索引
- [性能优化设计](02-性能优化设计.md) - 查询优化、批量操作

### 代码相关
- [项目结构设计](03-项目结构设计.md) - 目录结构、模块划分
- [核心模块设计](06-核心模块设计.md) - 同步管理、AI 服务
- [UI 交互设计](07-UI交互设计.md) - 焦点管理、按钮规范
- [设置页面设计](08-设置页面设计.md) - 设置窗口、Tab 布局
- [关于页面设计](09-关于页面设计.md) - 独立关于窗口、分段页面
- [国际化(i18n)设计](10-国际化(i18n)设计.md) - String Catalog、多语言支持
- [智能搜索栏交互设计](13-智能搜索栏交互设计.md) - 右上角搜索栏、Pro / AI 状态预留
- [AI 设置与调用链重构方案](15-AI设置与调用链重构方案.md) - 多服务商 BYOK、模型任务配置、Prompt 与流式调用链
- [Anthropic Messages API 服务商详细设计](68-Anthropic服务商详细设计.md) - Messages adapter 与设置页 `.anthropic` 类型
- [从 CC Switch 导入 AI Provider 详细设计](69-CC-Switch导入Provider详细设计.md) - 从 CC Switch SQLite 导入 BYOK Profile
- [活动页设计](16-活动页设计.md) - 活动聚合页、分类筛选、中栏卡片和右侧详情

### 技术选型
- [技术选型](04-技术选型.md) - 依赖库、SPM 配置

### API 相关
- [GitHub API 设计](05-GitHub%20API设计.md) - GitHub API 调用
- [活动页设计](16-活动页设计.md) - Release / Events / Starring / Watching 的活动聚合策略
- [项目健康度与维护活跃度设计](17-项目健康度与维护活跃度设计.md) - Community Profile / Stats / Advisories 接入与缓存
- [Starcat 数据贡献与数据平台详细设计](60-Starcat数据贡献与数据平台详细设计.md) - 客户端 opt-in、上传 DTO、outbox、删除与隐私边界
- [Starcat 自研仓库推荐系统详细设计](61-Starcat自研仓库推荐系统详细设计.md) - Trainer / Serving API、混合推荐、评估、灰度与收口
- [Starcat 自研星标历史服务详细设计](62-Starcat自研星标历史服务详细设计.md) - History ingest、聚合、构建、查询和 Discovery 迁移

---

## 文档更新记录

| 日期 | 更新内容 |
|------|---------|
| 2026-10-12 | 新增 70 文档：Linux.do 接入设计草案，记录通道实测、识别与跨分类来源方案，尚未实施 |
| 2026-09-13 | 新增 68 / 69 文档：Anthropic Messages 服务商与 CC Switch Provider 导入，均可直接落地 |
| 2026-08-25 | 新增 65 文档：统一 Agent / RAG 执行路由，规划 AI 服务、CLI、Harness、MCP、Agentic RAG 与安全桥接 |
| 2026-08-23 | 新增 64 文档：冻结 ACP 候选架构，明确当前暂缓接入、现有路径不迁移和重新评估门禁 |
| 2026-08-22 | 新增 60 / 61 / 62 文档：冻结匿名数据贡献、自研混合推荐、独立 Star History 服务及迁移落地契约 |
| 2026-08-22 | DeepSeek Harness POC 升级到外部安装的 `0.1.1rc1` wheel，明确不进入 App / DMG，并补充首次配置说明 |
| 2026-08-21 | 修订 58 文档：更新至 Harness `rc.8`，明确 Direct Sidecar、临时 MCP Bridge、插件白名单、版本更新与分阶段 POC |
| 2026-08-16 | 新增 58 文档：评估 DeepSeek Harness 外部 Runtime，并冻结 Direct-only POC 边界、协议缺口和验收门禁 |
| 2026-08-14 | 修订 57 文档：补齐 Agent Run Surface 的过程折叠、Activity Group、最终结果、Artifact 渲染与验收契约 |
| 2026-08-04 | 新增 57 文档：重写 Agent 工作台、RAG 上下文、MCP/CLI 能力复用、v19 迁移与产品化路线 |
| 2026-07-30 | 新增 56 文档：冻结 macOS 桌面小组件工程结构、快照契约、实施提交、测试和审查流程 |
| 2026-07-30 | 新增 54 / 55 文档：外部应用插件化扩展候选与 macOS WidgetKit 初步落地方案 |
| 2026-07-30 | 回填 53 文档：Raycast Extension、41 项自动化、构建证据与真机人工验收边界 |
| 2026-07-29 | 回填 53 文档：uTools 0.1.0 插件、公共 fixtures、Node 16 / 当前 Node 自动化证据与真机人工验收边界 |
| 2026-07-29 | 新增 53 文档：Alfred 代码审查门槛、共享 Launcher 契约、uTools / Raycast 可直接实施方案与验收清单 |
| 2026-07-29 | 新增 52 文档：Alfred Pro 外部搜索集成、CLI/MCP 契约、头像缓存、来源展示、三仓库实施顺序与验收方案 |
| 2026-07-29 | 新增 51 文档：我的项目一等分类、GitHub App 双授权、v17 数据关系、同步链路、现有详情与 Star History 复用方案 |
| 2026-07-27 | 回填 49 / 50 真实实现状态、最终文件与测试边界，明确 M0、部署和人工验收仍受授权门禁 |
| 2026-07-27 | 合并 49 / 50 文档：仓库星标历史改为仓库洞察内的 Star 趋势区块，共用一次 v16 迁移与验收链路 |
| 2026-07-27 | 新增 49 文档：我的洞察与仓库洞察的 Starcat 三栏接入、数据口径、远端缓存和分阶段实施方案 |
| 2026-07-24 | 新增 48 文档：Starcat 18 种语言范围、公开本地化协作、脚本与 CI、App 运行时和 RTL 验收契约 |
| 2026-07-21 | 新增 45 文档：六个后端服务的版本真源、构建注入、ping 契约、发布流程与分批验收方案 |
| 2026-07-21 | 新增 46 文档：记录快捷键首轮范围、应用命令路由、键位冲突和设置页归属 |
| 2026-07-18 | 同步 31 文档当前缓存策略：Trending 客户端改为 1h/6h/24h 分桶，Weekly 客户端与后端统一为 6h |
| 2026-07-16 | 新增 42 文档：Weekly 多来源采集、异步 Worker、HelloGitHub、AI 情报 Skill、动态来源缓存与置顶实现契约 |
| 2026-07-03 | 新增 37 文档：External Search Provider 抽象、SearchCenter 单 Provider View、AI External Context 单 Provider / Pro 聚合、Provider 隔离缓存与本机凭据边界 |
| 2026-07-03 | 重写 30 文档：本地 RAG 从“已 star 仓库问答”调整为“知识库问答”，补齐 chunk-level 索引、独立工作台、引用证据与实施切片 |
| 2026-06-29 | 新增 36 文档：CodebaseMemory 集成设计（二进制打包进 bundle + POSIX 端口探测 + Process spawn + 6 步状态机 + App Store 沙盒签名策略）；补登 34/35 索引 |
| 2026-06-15 | 31 文档微调：BulkCache TTL 60s → 6h（多客户端并发 / 主动刷新风暴场景下减少反复 build；与 trending weekly 桶对齐；演进记录写入 §8） |
| 2026-06-15 | 新增 31 文档：R-06 Trending / Weekly 多级缓存改造收尾记录（客户端 SQLite TTL + 后端内存缓存 + Weekly 渐进式 SWR 双轨制 + 3 个永久陷阱 + 关键决策一览） |
| 2026-06-15 | 新增 29 / 30 两份文档：29 把已实施的关键词 + 向量语义双引擎搜索逻辑沉淀为单一信任源（含三段式加权常量 / 示例走查 / 后期优化方向）；30 探索把已 star 仓库做成本地 RAG 的产品愿景（chunk-level retrieve + 引用约束 + UI/UX 草案 + 功能优先级 + 落地路线） |
| 2026-06-13 | 新增搜索增强最终方案：结合 AnySearch / GitHub 搜索需求、`d9bd9f7` 命令搜索浮层与当前主线代码，收敛为“Manage 快速过滤 + 全局搜索中心”双入口 |
| 2026-06-12 | 文档命名规范化：详细设计 21~25 + 需求讨论 4 份重命名（详见 `工程进度/功能实现总览.md` §10）；本次同步：补齐 21/22/23/24/25 索引行，统一描述风格 |
| 2026-06-11 | 添加 starcat-wiki-api 客户端对接文档 v1.0（20-wiki-api-对接.md ~580 行 14 节,e2e 11/11 全绿,8 项技术债 + 13 项客户端落地 checklist）;同时把已存在但漏登的 18-三场景共用架构 + 19-wiki集成 补入索引 |
| 2026-06-10 | （R-02 改造期）19-wiki集成.md 经历 v0.5 翻转(zread 周 trending 从 trending-api 迁出 + 并入 weekly-api + 4 项决策同步确认) |
| 2026-06-10 | 18-三场景共用架构.md 持续迭代至 R-01 v2.0 修订(registry 信任源问题根治) |
| 2026-06-05 | 添加项目健康度与维护活跃度设计文档（HOM-92） |
| 2026-06-04 | 添加活动页设计文档 |
| 2026-06-04 | 添加 AI 设置与调用链重构方案 |
| 2026-06-02 | 添加智能搜索栏交互设计文档 |
| 2026-05-31 | 添加国际化(i18n)设计文档 |
| 2026-05-31 | 添加关于页面设计文档 |
| 2026-05-31 | 添加设置页面设计文档 |
| 2026-05-31 | 添加 UI 交互设计文档 |
| 2026-05-29 | 初始版本 |
