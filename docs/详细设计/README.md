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
| 30 | [本地 RAG 设计](30-本地RAG设计.md) | 探索性方案 v0.1（P2 远期）：把 1810+ 已 star 仓库做成本地 RAG，三层架构（chunk-level retrieve + 可选 rerank + LLM 生成 + 引用 chip）、UI / UX 草案、功能列表与落地路线 |
| 31 | [Trending / Weekly 多级缓存改造](31-Trending-Weekly缓存改造.md) | R-06 完整记录：客户端 SQLite TTL（Trending 24h / Weekly 12h）+ 后端内存缓存（trending 分桶 1h/6h/24h + ETag、weekly 6h + pre-gzip + bulk endpoint）+ Weekly 渐进式 SWR 双轨制（dataSource .local/.remote）、3 个永久陷阱、关键决策一览、4 个项目共 33 个新测试用例验证 |

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
