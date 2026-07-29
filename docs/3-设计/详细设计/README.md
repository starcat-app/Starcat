# 详细设计

> 本目录包含 Starcat 项目的详细技术设计文档。

---

## 文档索引

| 编号 | 文档 | 内容 |
|------|------|------|
| 01 | [数据库设计](01-数据库设计.md) | GRDB Schema、表结构、FTS5、索引优化 |
| 02 | [性能优化设计](02-性能优化设计.md) | 列表优化、README 缓存、内存优化 |
| 03 | [项目结构设计](03-项目结构设计.md) | 目录结构、模块划分、命名规范 |
| 04 | [技术选型](04-技术选型.md) | 依赖库、平台兼容性、第三方服务 |
| 05 | [GitHub API 设计](05-GitHub%20API设计.md) | OAuth、端点、Rate Limit、同步策略 |
| 06 | [核心模块设计](06-核心模块设计.md) | SyncManager、AI 服务、Keychain、日志 |
| 07 | [UI 交互设计](07-UI交互设计.md) | 焦点管理、按钮规范、Popover 交互 |
| 08 | [设置页面设计](08-设置页面设计.md) | 设置窗口、Tab 布局、偏好项设计 |
| 09 | [关于页面设计](09-关于页面设计.md) | 独立关于窗口、分段页面、致谢页面 |
| 10 | [国际化(i18n)设计](10-国际化(i18n)设计.md) | String Catalog、SwiftUI 本地化、多语言扩展 |
| 13 | [智能搜索栏交互设计](13-智能搜索栏交互设计.md) | 右上角快速搜索、Pro / AI 搜索预留、toolbar 交互 |
| 15 | [AI 设置与调用链重构方案](15-AI设置与调用链重构方案.md) | 多服务商 BYOK、任务模型选择、参数、Prompt、流式摘要 |
| 16 | [活动页设计](16-活动页设计.md) | Activity 聚合页、Release / Events / 本地推荐、三栏接入 |
| 17 | [项目健康度与维护活跃度设计](17-项目健康度与维护活跃度设计.md) | 规则评分 + AI 解释、Community Profile / Stats / Advisories 缓存、Insights UI、License 风险分类 |
| 18 | [三场景共用架构](18-三场景共用架构.md) | Manage / Trending / Weekly / Activity 4 场景的 UI 骨架 + 行为契约共用架构（R-01 v1.2~v2.0） |
| 19 | [wiki 集成](19-wiki集成.md) | starcat-wiki-api 服务端设计（v0.1~v0.5 五次翻转历史 + 4 场景接入 + zread 接入评估）|
| 20 | [starcat-wiki-api 客户端对接](20-wiki-api-对接.md) | wiki-api 客户端对接手册 v1.0：端点契约 + DTO + 详情页 UI 集成 + 8 项技术债 + 13 项落地 checklist |
| 21 | [weekly-api 后端 3 源聚合改造](21-weekly-api-后端3源聚合改造.md) | R-04：把 weekly / zread / discovery 3 表 3 端点重构为主表 `github_repos` + 4 附表 + 1 聚合接口 `/api/v1/repos`，gh_repo_id 主键 |
| 22 | [weekly 客户端 3 源聚合对接](22-weekly-客户端3源聚合对接.md) | R-04 配套客户端方案：列表换 3 源合并 feed、列表 repo name / 详情 full_name 同行展示来源标识，客户端只展示和筛选不参与聚合 |
| 23 | [Chrome 插件方案](23-Chrome-插件方案.md) | Starcat Companion Chrome 插件总体方案 v1.0：URL Scheme + 本地 HTTP 双向通信、5 项 MVP（状态胶囊 / 一键采集 / 笔记追加 / 浮按钮 / 角标）、与 R-04 主表 `source=clip` 接入 |
| 24 | [GitHub 搜索集成设计](24-GitHub-搜索集成设计.md) | 系统级 / 工具级 GitHub 搜索集成方案 |
| 25 | [Show HN 发现源设计](25-Show-HN发现源设计.md) | AI Discovery（Show HN 官方 API + LLM 单标签分类，Activity 第 8 个具体分类），v1.1 后端已实现，客户端待接入 |
| 28 | [搜索增强最终方案](28-搜索增强最终方案.md) | 保留 Manage 快速过滤，新增 `⌘K` 全局搜索中心，聚合 Local / GitHub / AnySearch Web 并复用现有详情与动作体系 |
| 29 | [关键词与全文检索设计](29-关键词与全文检索设计.md) | 双引擎落地实现：FTS5（repos_fts unicode61 + notes_fts trigram + BM25 排序）+ 向量语义（A 显示重标定 + B 字面 boost + C FTS hit 加权 + tier 1-4★）+ 示例走查 + 后期优化方向 |
| 30 | [本地 RAG 设计](30-本地RAG设计.md) | 知识库 RAG 详细设计：默认只使用 `libraryState == .inLibrary` repo，新增 chunk-level RAG 索引、知识库问答工作台、citation chip 与 evidence inspector |
| 31 | [Trending / Weekly 多级缓存改造](31-Trending-Weekly缓存改造.md) | R-06 完整记录：客户端 SQLite TTL（Trending 分桶 1h/6h/24h、Weekly 6h）+ 后端同窗口内存缓存（ETag / pre-gzip / bulk endpoint）+ Weekly 渐进式 SWR 双轨制（dataSource .local/.remote） |
| 32 | [Manage 列表分页与首页边沿上屏](32-Manage列表分页与首页边沿上屏.md) | Manage 列表分页、首页边沿上屏与滚动体验调整 |
| 33 | [OpenSSF Scorecard 安全评分设计](33-OpenSSF-Scorecard-安全评分设计.md) | 已 star 仓库 OpenSSF Scorecard 缓存、列表 full_name 行徽章、详情页雷达图、后台刷新、i18n 与测试边界 |
| 34 | [StarcatCLI 与外部 MCP 桥接设计](34-StarcatCLI与外部MCP桥接设计.md) | stdio MCP adapter + CLI 入口,解决 Codex / 老式 client 不兼容 HTTP MCP 的兼容性问题 |
| 35 | [GitHub Stars List 分组设计](35-GitHub-Stars-List分组设计.md) | GitHub Stars List 分组侧边栏入口 + OAuth 组织限制处理 |
| 36 | [CodebaseMemory 集成设计](36-CodebaseMemory集成设计.md) | codebase-memory-mcp 二进制打包进 bundle + 持久解压 + POSIX 端口探测 + Process spawn UI 子进程 + 6 步状态机 + 设置页/Storage Tab 集成 + App Store 沙盒与签名策略 |
| 37 | [外部搜索服务设计](37-外部搜索服务设计.md) | External Search Provider 抽象、设置页、SearchCenter Provider View、External Context 单 Provider / Pro 聚合与缓存策略 |
| 42 | [Weekly 多来源采集与置顶](42-Weekly多来源采集与置顶.md) | 固定来源目录、持久化 enrich 队列、HelloGitHub 回填、AI 情报 Skill、动态来源缓存与多项目置顶的落地契约 |
| 45 | [后端服务版本注入与 Ping 契约](45-后端服务版本注入与Ping契约.md) | 六个 Go 服务统一以 release tag 为真源，经 Docker build arg 与 linker `-X` 注入版本，并由 `/api/v1/ping` 返回 |
| 46 | [快捷键与应用命令设计](46-快捷键与应用命令设计.md) | Stars 同步、RAG 工作台与当前仓库 AI 的快捷键、上下文命令路由、冲突校验和设置页归属 |
| 48 | [18 种语言本地化扩展详细设计](48-18种语言本地化扩展详细设计.md) | 18 个 Locale 的仓库边界、xcloc 状态机、导入导出、CI 门禁、运行时接入、RTL 与验收方案 |
| 49 | [洞察中心详细设计](49-洞察中心详细设计.md) | 已实现：我的洞察、仓库洞察、v16 缓存、结构化下钻、GitHub 活动与 Star 趋势；外部授权门槛单列 |
| 50 | [仓库星标历史整体落地方案](50-仓库星标历史整体落地方案.md) | 已实现本地快照、Discovery API 与趋势 UI；M0 真实 BigQuery 验证、部署与人工验收待授权 |
| 51 | [我的项目整体落地方案](51-我的项目整体落地方案.md) | 星标模块下的个人 / 组织 / Private 项目分类、GitHub App 只读授权、v17 关系表、同步、详情复用与隐私边界 |
| 52 | [Alfred 外部搜索集成详细设计](52-Alfred外部搜索集成详细设计.md) | Starcat Pro 外部集成：复用 CLI/MCP 全局搜索、跨来源去重、owner avatar 缓存、Deep Link / GitHub 打开与三仓库实施验收契约 |
| 53 | [uTools 与 Raycast 外部搜索集成详细设计](53-uTools与Raycast外部搜索集成详细设计.md) | 复用 `starcat search` 公共契约，定义 uTools list 插件、Raycast Extension、头像差异、取消机制、独立仓库与发布验收 |

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
- [活动页设计](16-活动页设计.md) - 活动聚合页、分类筛选、中栏卡片和右侧详情

### 技术选型
- [技术选型](04-技术选型.md) - 依赖库、SPM 配置

### API 相关
- [GitHub API 设计](05-GitHub%20API设计.md) - GitHub API 调用
- [活动页设计](16-活动页设计.md) - Release / Events / Starring / Watching 的活动聚合策略
- [项目健康度与维护活跃度设计](17-项目健康度与维护活跃度设计.md) - Community Profile / Stats / Advisories 接入与缓存

---

## 文档更新记录

| 日期 | 更新内容 |
|------|---------|
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
