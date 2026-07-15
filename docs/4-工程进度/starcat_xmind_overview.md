# Starcat 功能总览（XMind 兼容版 · 截至 2026-06-28）

> 用途：用 XMind 打开本文件即可生成项目功能思维导图，直观查看「已完成 / 未完成」分布。
>
> **打开方式**：XMind → 文件 → 导入 → Markdown → 选本文件。
>
> **数据源（覆盖范围 C = 全量）**：
> - `docs/功能实现总览.md`（活文档主索引，284 项 checkbox）
> - `docs/2-产品/需求讨论/v2-功能规划.md`（v1 上架后 backlog，~20 项）
> - `docs/发展规划.md §13(详见 `docs/3-设计/详细设计/23-Chrome-插件方案.md`) 推荐实施顺序`（5 阶段）
> - `docs/2-产品/需求讨论/agent/*`（agent 方向研究 / 方案）
>
> **状态符号约定**：
> - `- [x]` 已完成
> - `- [ ]` 未开始 / 待办
> - `- [~]` 部分完成 / 进行中（XMind 中按普通节点显示）
> - `[P0]` / `[P1]` / `[P2]` 优先级后缀
> - `[W?]` 计划周次
> - `` `文件路径` `` 关联代码
>
> **不适用符号**：XMind 导入 markdown 时 `- [x]` / `- [ ]` 会作为节点文字前缀保留，不会自动转为 XMind 原生 task 节点。如需 task 图标需在 XMind 内右键 → Task。
>
> ---
>
> 维护者：dong4j。**单文件全量快照**，与 `功能实现总览.md` 同步生成；源头变更后需重新生成本文件。
>
> **简化约定**：每条 checkbox 只保留 `状态 + 功能名 + 必要的 followup / 约束标记`；详细描述、文件路径、日期、嵌套代码均省略；完整版见 `docs/功能实现总览.md`。

## 📊 进度仪表盘

- 文档生成日期：2026-06-28
- 总 checkbox 数量：284 项
- 已完成 `[x]`：208 项
- 未完成 `[ ]`：76 项
- 主章节：11 个（§0 / §3 / §4 / §5 / §6 / §7 / §8 / §9 / §10 / §11 + 仪表盘）
- v2 Backlog 增量：~20 项
- Agent 方向方案文档：~25 份
- 总覆盖：P0 + P1 + P2 + 工程债 + 非功能需求 + 上架准备 + v2 Backlog + Agent 方向 + 实施阶段

---

## §0 近期新增功能（2026-06-20 起，不属于 P0/P1 增量补丁）

### §0.3 MCP Service（2026-06-20）
- [x] MCP Service P0
- [x] MCP Service 写入 P0
- [x] MCP Service 端口 UX 与重启预检
- [x] MCP 30s timeout 修复（macOS 26 IPv4/IPv6 listener mismatch）
- [x] MCP runtime 会话与端口重启修复

### §0.5 错误处理与诊断日志（2026-06-20）
- [x] 错误处理与诊断日志 P0
- [x] 启动页恢复登录兜底

### §0.6 主窗口状态面板（2026-06-20）
- [x] 主窗口状态面板

### §0.7 通知策略优化（2026-06-20）
- [x] 低频必要通知策略

### §0.8 Smart Collections + Repo Health（2026-06-20）
- [x] Smart Collections 方案确认
- [x] Repo Health 方案确认
- [x] Repo Health P1
- [x] Smart Collections P1
- [x] Smart Collections v2.1 高阶过滤 + 规则编辑器
- [x] Smart Collections v2.2 metadata 补全
- [x] Smart Collections v2.3 质量 / Release
- [x] Smart Collections v2.4 标签 / 搜索增强 + 模板

### §0.9 Activity / Weekly 体验优化（2026-06-24）
- [x] Weekly 来源筛选

---

## §3 P0 - MVP 必须功能

### §3.1 账号与同步（W1 + W2）
- [x] GitHub OAuth 登录
- [x] AuthSession 状态机
- [x] 首次使用引导 v3
- [x] 集中式 401 处理
- [x] Stars 全量同步
- [x] Rate Limit 解析
- [x] 同步状态展示
- [x] Stars 增量同步
- [x] Rate Limit 主动退避
- [x] ETag 缓存
- [ ] Web Application Flow OAuth [W6+]
- [x] Token 存储安全收口 (D-16)
- [x] 登录页 V2 设计探索（独立预览版）

### §3.2 主界面（三栏布局）（W3）
- [x] macOS 三栏 NavigationSplitView 骨架
- [x] All Repos 视图
- [x] Untagged 视图
- [x] Languages 视图
- [x] 列表密度切换
- [x] Sidebar 用户卡
- [x] 贪吃蛇多玩法 + Settings 配置项（HOM-SNAKE-MODES）
- [x] 当前用户 profile 离线缓存 + 后台刷新（HOM-175）
- [x] Starred 列表单文件导出 HTML / Markdown（HOM-174）
- [x] 用户分享卡片（HOM-173）
- [x] Sidebar 个人主页信息行 + 贡献草坪 + 贪吃蛇动画（HOM-PROFILE）
- [x] Cmd+, 设置面板
- [x] 主窗口默认尺寸与位置恢复
- [x] Tags 视图
- [x] 排序功能
- [x] 主页操作按钮按三栏职责拆分 + Finder 式搜索框
- [x] Sidebar Tags / Languages 折叠 header 修复
- [x] HOM-46 切换分类时 repo 列表加载慢优化
- [x] 已登录用户重开 App 默认进入 Manage + 恢复上次分类
- [x] 中栏导航面包屑与跨页面数量副标题
- [ ] macOS 26 Liquid Glass 适配 [W4+]

### §3.3 Repo 详情
- [x] 元数据展示卡片
- [x] 详情页信息区高度优化
- [x] 详情页滚动隐藏信息面板
- [x] README WebView 渲染
- [x] README 抓取 + 缓存（含 ETag）
- [x] README 缓存软过期（softTtl） + 404 session 缓存
- [x] README SWR + API 拆分（Phase 2）
- [x] HTTPS / SSH Clone URL 复制
- [x] GitHub 页面快捷入口
- [x] 取消 Star 操作
- [ ] 详情页信息增强：Website 显示
- [ ] 详情页信息增强：Open Issues 数（含 PR）
- [ ] 详情页信息增强：Open PR 数（独立）
- [ ] 详情页信息增强：最新 Release
- [ ] 独立 README 窗口 [P2]
- [ ] Pin 置顶窗口 [P2]

### §3.4 整理功能（W4）
- [x] 标签 CRUD
- [x] 标签颜色 / 图标
- [x] 给 repo 打标签 / 解除
- [x] 批量添加标签
- [x] GitHub Stars List 仓库分组
- [x] 私有笔记编辑
- [x] 状态管理（未读/在读/在用/废弃）

### §3.5 搜索与过滤（部分 W3）
- [x] FTS5 全文搜索
- [x] 全局搜索框 + 显式提交搜索
- [x] FTS 查询安全化
- [x] FTS5 召回扩展 + BM25 排序 + notes_fts 用 trigram tokenizer
- [x] 按语言过滤
- [x] 按标签过滤
- [x] 按状态过滤
- [x] 按 Archived / Fork 过滤
- [x] Search Center `.web` 空态「点击开启 AnySearch」
- [x] 网页搜索对所有用户开放（放开 Pro 限制）
- [ ] 结构化搜索页 [W5]
- [ ] 保存搜索 [P1]

### §3.6 数据管理（部分 W1）
- [x] 本地 SQLite 缓存
- [x] Migration v1
- [ ] JSON 导入
- [ ] JSON 导出
- [x] 缓存清理

### §3.7 关于窗口（W4）
- [x] 系统原生关于窗口定制
- [x] App Store 系统评分入口

### §3.8 设置项偏好
- [x] 主题切换
- [x] 关闭应用内动画（无障碍）
- [x] Storage 本机恢复出厂

### §3.9 后端 API 扩展（zread 周 trending 多源化 + trending-api GitHub 单源化）（2026-06-10）

#### §3.9.1 weekly-api 新增 zread 周 trending 端点（v0.5.0，2026-06-10）
- [x] weekly-api 新建 internal/spider/zread.go + zread_types.go
- [x] weekly-api model/zread_trending.go + envelope
- [x] weekly-api store/sqlite.go 加 migrateV3()
- [x] weekly-api handler/zread_trending.go + 路由
- [x] weekly-api scheduler/cron.go 加 zread 周一 06:00 任务
- [x] weekly-api 端到端验证（go build / vet / test / curl）
- [x] weekly-api CHANGELOG.md v0.5.0 + README.md 端点文档

#### §3.9.2 trending-api GitHub 单源首发（v0.1.0，2026-06-10）
- [x] trending-api 全量清理 v0.3 zread 集成残留 + 收为 v0.1.0 首发

#### §3.9.2.1 trending-api 全新服务单测基线（v0.1.1）
- [x] trending-api 补齐 7 包/75 项单测（0 → 75，build/vet/test 全绿）

#### §3.9.3 Weekly 客户端对接（已并入 §3.9.8 R-05）
- [x] Weekly 客户端 3 源聚合对接

#### §3.9.4 4 服务统一"全新服务"语态（2026-06-10 23:00）
- [x] starcat-sharing-api：拆 migrations.go 为 createSchema
- [x] starcat-weekly-api：拆 sqlite.go 内联 V1/V2/V3 为 createSchema
- [x] starcat-wiki-api：拆 migrations.go 为 createSchema

#### §3.9.5 待办
- [x] Weekly 客户端对接
- [x] wiki-api 客户端对接方案 v2 实施

#### §3.9.6 wiki-api 客户端对接文档 v1.0（2026-06-11）
- [x] wiki-api 客户端对接手册 v1.0
- [x] 按当前 v2 后端与 Starcat 架构重写客户端对接方案

#### §3.9.7 trending sidebar 语言列表聚合改造（2026-06-11 20:00）
- [x] 后端 `/api/v1/languages` 改为基于 `trending_repos` 实际数据聚合 + 客户端 sidebar 切换数据源

#### §3.9.8 R-04 / R-05 weekly 3 源聚合（2026-06-12）
- [x] R-04 后端设计按最新代码校准
- [x] R-04 后端实施
- [x] weekly-api scheduler 三源并行冷启动 + weekly issue 增量跳过
- [x] R-05 客户端设计按最新代码校准
- [x] R-05 客户端实施

---

## §4 P1 - 第一版 AI 功能

### §4.1 Release 订阅追踪（差异化功能）（W6 9/9 完成；HOM-47）
- [x] Release API 拉取
- [x] Release 订阅 / 取消订阅
- [x] 后台轮询调度器
- [x] 新 Release 通知
- [x] Release 时间线视图
- [x] 已读 / 未读管理
- [x] 智能资产过滤
- [x] 一键复制下载链接
- [x] 直接下载

### §4.2 AI 摘要与分析（W6）
- [x] AI 服务配置 UI
- [x] AI API Key 本地存储
- [x] 单仓 AI 摘要
- [x] AI 标签推荐
- [x] AI 确认流程
- [x] AI 结果本地缓存
- [x] AI 助手浮动窗口（摘要 + 对话）
- [x] backend AI 分享页模板视觉重做
- [ ] 同义标签检测 [W6]
- [ ] 14 预设分类 [W7]
- [ ] 支持平台识别 [W7]
- [ ] 批量未分类整理 [W7]
- [x] 自动后台 AI 整理（设置驱动 + 调度器）
- [x] README 翻译
- [x] AnySearch 检索结果磁盘缓存（HOM-69）
- [x] AI 对话历史磁盘持久化 + 多 session 管理（HOM-70）
- [x] RepoContextPacker（AI 摘要上下文打包）

### §4.3 AI 语义搜索（W7+）
- [x] Embedding 服务端计算
- [x] 向量本地存储
- [x] 向量搜索召回与展示三段式增强（A 重标定 + B 字面 boost + C FTS hit 加权 + 阈值单位迁移）
- [x] 向量搜索改进：三级降级 indexedText + 行级 diff 阈值 + 后台慢速预拉
- [x] Summary / Tags / Chat 任务 prompt 模块化重构（占位符归一化方案 C + i18n + Chat 首次模板化 + AnySearch 信任语义升级）
- [x] Embedding 任务 prompt 占位符化
- [ ] 自然语言查询 [W7]
- [ ] 命中原因说明 [W8]

### §4.4 AI 每日推荐 / Trending（W7+）
- [x] GitHub Trending 抓取
- [x] 日榜 / 周榜 / 月榜筛选
- [x] Trending 项目 AI 摘要
- [x] 个性化推荐
- [x] 一键订阅到 Stars
- [x] AI 评分算法
- [x] Trending 列表 + README GRDB 持久化（与 Manage 同构）
- [x] Activity 聚合页第一版

#### Activity 公告与关注 — 数据接入（2026-06-16 启动，3 PR 切分）
- [x] PR-1：数据库 + Repository + i18n 骨架（不接网络）
- [x] PR-2：following GitHub Events 接入 + SWR 改造
- [x] PR-3：announcement Blog RSS + Security Advisory
- [x] PR-3 v3.1：切分类卡顿 + 公告/关注空数据修复
- [x] PR-3 v3.2：公告排序 + 详情布局 + 缓存首屏

### §4.5 保存搜索（从 P0 推迟）
- [ ] 保存复杂搜索条件 [P1]
- [x] 搜索增强：全局搜索中心（Local + GitHub + AnySearch Web）

### §4.6 Weekly Hacker News 来源

- [x] HN 官方 API Collector + GitHub URL 提取与 enrich
- [x] Show HN 作为 Weekly `discovery` 来源完成筛选、图标、详情链接与 bulk 本地缓存
  > 原 Activity 独立 AI Discovery 客户端计划取消；后续通用来源改造见 §9.3 最终方案。

---

## §5 P2 - 远期 / 后续迭代

### §5.1 多端同步（W5 已规划 CloudKit 部分）
- [ ] CloudKit Schema 设计 [W5]
- [ ] CloudKit 推送 [W5]
- [ ] CloudKit 拉取 + 合并 [W5]
- [ ] 后台同步调度 [W5]
- [ ] 冲突解决 UI [W5]
- [ ] iPhone 适配 [P2]
- [ ] iPad 适配 [P2]
- [ ] watchOS companion

### §5.2 Apple 生态集成
- [ ] 菜单栏入口 [P2]
- [ ] 全局快捷键 [P2]
- [ ] Spotlight 搜索 [P2]
- [ ] Shortcuts 支持 [P2]
- [ ] Widget [P2]

### §5.3 订阅系统
- [x] StoreKit 2 接入
- [x] Pro 订阅方案
- [x] AI / 数量门控
- [x] 恢复购买
- [ ] Direct 分发 + Lemon Squeezy 授权码 [P2]
- [ ] BYOK 模式 [P2]

### §5.4 AI 高级功能
- [x] 项目健康度评分
- [x] OpenSSF Scorecard 安全评分
- [ ] AI 周报 [P2]
- [ ] 调研报告生成 [P2]
- [ ] 对比报告 [P2]
- [ ] Awesome List 导出

### §5.5 效率功能
- [ ] 独立 README 窗口 [P2]
- [ ] Pin 置顶窗口 [P2]
- [ ] 最近查看历史 [P2]
- [ ] 常用标签快速访问 [P2]
- [x] CodeFlow 集成

### §5.6 浏览器伴侣（Starcat Companion Chrome 插件）
- [x] 总体方案 v1.0 落档
- [ ] V0.1 MVP 实施
- [ ] V0.2 增强
- [ ] V0.3 跨站采集

---

## §6 工程债 / 重构清单（与功能并列）

### §6.1 P0 重构（W4 开工前必做）
- [x] D-04：`HomeViewModel` mutable 收敛为 `private(set)`
- [x] D-03：`as! T` 强转改安全分支
- [x] D-05：`reloadItems` 加 Task 取消
- [x] D-02：抽 `GitHubAPIClientProtocol`
- [x] D-01：抽 `RepoRepositoryProtocol` + 具体类改名 `GRDBRepoRepository`

### §6.2 P1 重构（W4 内穿插做）
- [ ] D-06：DTO → Model 映射移到 DTO extension
- [ ] D-07：抽公共组件到 `Shared/`
- [ ] D-08：命名规范文档
- [ ] D-09：`AppDependencies` 去 `@Observable`

### §6.3 P2 重构（择机）
- [x] D-30：多账号 DB 隔离改造（按 GitHub User ID 物理切分 SQLite 目录）
- [x] D-27：WeeklyDetailView 切换 repo 卡顿 + 旧 repo 视觉残留三步修复（loadAll fallback + 删 .id + resolveRepo silent upgrade）
- [x] D-26：WeeklyDetailView.resolveRepo 步骤 1a 加 fullName 匹配守卫（D-24 followup）
- [x] D-25：GitHub 301 重定向丢失 Authorization → 401 被误判为 token 失效 → 自动登出
- [x] D-24：weekly / activity 详情页 hero star 不同步真值的两个独立 corner case 修复（D-22 followup）
- [x] D-22：`Repo.==` 从 id-only 回归全字段比较，修 SwiftUI view diffing 跳过 hero 重渲染的根因
- [x] D-21：数据库迁移大合并：v1~v9 + R-05 共 9 个迁移摊平为单一 `v1-initial`
- [x] D-28：4 详情页 root 切换 transition 同构补齐（v1/v2 折回 + v3 Shell 重构）
- [x] D-29：weekly 详情页 sidebar 头像背景色不跟语言色联动（manage / trending / activity 已联动）
- [x] D-31：空状态视图重复代码消除 + 浅色主题对比度修复（13 空态 + 4 AI caption 统一 EmptyStateView）
- [x] D-32：同账号重开 App 启动刷新卡顿修复（会话恢复误判 + 启动 sync TTL + 304 跳过）
- [ ] D-23：`StarringSubsystem.attachHomeRefresher` 调用点缺失
- [ ] D-10：Logger level 使用规范
- [ ] D-11：Kingfisher 缓存上限配置
- [ ] D-12：搜索防抖时间常量化
- [ ] D-15：DatabaseManager 启动失败友好提示
- [ ] D-17：`RepoRowSurface` / `TrendingRepoRowSurface` 视觉容器抽公共
- [x] D-18：自建后端 API baseURL 集中化 + 本地开发 env 覆盖
- [x] D-20：所有 REST 端点集中目录化（AppEndpoints 重构 v3）
- [x] D-19：第三方服务 URL 运行时配置（设置页 → 服务 Tab）

### §6.4 测试覆盖补齐（P3）
- [ ] D-13：AuthSession / SyncManager / HomeViewModel / NetworkError 单测
- [x] D-14：GitHubAPIClient URLProtocol stub 单测
- [x] T2.8（延期项归还）：ReadmeAPI 网络路径单测
- [x] D-36：`RepoCardViewData.healthBadge` 测试 mock 漂移

### §6.5 ⚠️ 发布前必做（绝不能漏）
- [x] D-16：Token 存储安全收口
- [x] D-33：MCP `tools/list` 返回 0 tools
- [x] D-34：MCP `tools/call` 返回 "MCP registry is unavailable"
- [x] D-35：Claude 重连时 MCP server 返回 -32600 "Server is already initialized"
- [x] R-01：三场景共用架构（manage / trending / weekly / activity-repo-backed）
- [x] R-06：Trending TTL + Weekly 渐进式 SWR 缓存（客户端 + 2 后端三层缓存）
- [x] R-07.1：sync 完成后列表卡在已滚到的页（hasMore false→true 视图层主动 push）
- [x] R-07：Manage 列表客户端分页 + 首次登录第一页边沿上屏

---

## §7 非功能需求清单（验收时核对）

### §7.1 性能要求
- [ ] 启动时间 < 2 秒
- [ ] 列表滚动 60 FPS
- [ ] 搜索响应 < 500ms
- [ ] AI 摘要生成 < 5 秒

### §7.2 隐私要求
- [x] 本地优先架构
- [x] 数据分离
- [ ] BYOK 模式不过 Starcat 服务器
- [ ] 隐私政策页面

### §7.3 兼容性
- [x] 最低 macOS 15 (Sequoia)
- [ ] macOS 26 Liquid Glass 优先

### §7.4 UI 视觉升级专题
- [x] UI 优化指导手册
- [x] UI 视觉升级样板：Repo List row
- [x] UI 视觉升级样板：Trending repo row 渐进式入场
- [x] UI 视觉升级样板：Trending 卡片 chip 抽公共组件 + 视觉对齐 Manage（Step 2）
- [x] UI 视觉升级样板：Trending 卡片选中态对齐 Manage repo row
- [ ] UI 视觉升级样板实现

---

## §8 上架准备清单（发布前 checklist）
- [ ] Apple Developer Program 注册
- [x] App 图标
- [ ] 截图
- [ ] 隐私政策 HTTPS 托管
- [ ] App Store 描述文案
- [ ] 截图标语
- [ ] TestFlight 内测
- [ ] App Sandbox 审核合规检查
- [x] App Store 系统评分入口
- [x] Token 加密存储（原 D-16）

---

## §9 v2 Backlog（v1 上架后迭代，从 `docs/2-产品/需求讨论/v2-功能规划.md`）

### §9.1(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 详情页 Hero 信息增强（dong4j 2026-06-17 延期至 v2）
- [ ] Website 内联显示 [P1]
- [ ] Open Issues 数（含 PR） [P1]
- [ ] Open PR 数（独立） [P1]
- [ ] 最新 Release 内联展示（未订阅可见） [P1]

### §9.2(详见 `docs/6-发版与上架/v1-上架信息准备.md`) JSON 导入 / 导出（原 P0 延后）
- [ ] JSON 导入
- [ ] JSON 导出

### §9.3 Weekly 多来源、HelloGitHub、AI 情报与置顶运营
- [ ] weekly-api 通用来源事件与异步 enrich Worker
- [ ] HelloGitHub 增量采集与历史月刊回填
- [ ] AI 情报批量录入 API 与 `starcat-weekly-import` skill
- [ ] Starcat Weekly 动态来源、图标、本地缓存与置顶排序
- [ ] `_local-admin` 来源状态、回填与置顶管理
  > 最终方案：`docs/2-产品/需求讨论/正式方案/Weekly多来源扩展与AI情报采集正式方案.md`

### §9.4(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 导出 Starred 到 GitHub Awesome 仓库（基于 mawesome 思路）
- [ ] Awesome 导出配置
- [ ] README 生成引擎
- [ ] GitHub 推送
- [ ] 定时同步（可选）

### §9.5(详见 `docs/6-发版与上架/v1-上架信息准备.md`) Trending 推荐栏目（基于 GitHub Issues）
- [ ] 推荐仓库配置
- [ ] Trending 推荐列表
- [ ] 推荐详情页
- [ ] Issue 互动（可选，后期）

### §9.6(详见 `docs/6-发版与上架/v1-上架信息准备.md`) StoreKit 2 + Pro 付费墙
- [ ] StoreKit 2 + Pro 付费墙

### §9.7(详见 `docs/6-发版与上架/v1-上架信息准备.md`) CloudKit 多端同步（与 §5.1 同源）
- [ ] CloudKit 多端同步

### §9.8(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 其它 v2 候选
- [x] Show HN 已作为 Weekly Hacker News 来源落地；Activity 独立客户端计划取消

---

## §10 Agent 方向（从 `docs/2-产品/需求讨论/agent/*`，本地优先开源项目知识库路线）

### §10.1(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 混合语义搜索与本地向量索引
- [x] Embedding 服务端计算
- [x] 向量本地存储
- [x] 向量搜索召回与展示三段式增强
- [ ] 自然语言查询
- [ ] 命中原因说明
- 已有方案：`docs/2-产品/需求讨论/agent/18-Qdrant-语义搜索迁移方案.md`（Qdrant 迁移研究）/ `docs/2-产品/需求讨论/agent/17-Meilisearch-调研与本地集成方案.md`（Meilisearch 集成研究）

### §10.2(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 仓库推荐算法
- [ ] 基于用户行为的个性化推荐
- [ ] 自建仓库推荐系统
- 已有方案：`docs/2-产品/需求讨论/agent/19-推荐训练-内容向量vs行为训练与用户行为采集.md` / `docs/2-产品/需求讨论/agent/21-自研相似仓库推荐算法-设计方案.md` / `docs/2-产品/需求讨论/agent/16-仓库推荐算法-SimRepo接入与自研方案.md` / `docs/2-产品/需求讨论/agent/starcat_repo_research_agent_design.md`

### §10.3(详见 `docs/6-发版与上架/v1-上架信息准备.md`) AI 项目分析工具集成（Level 1/2/3 分层）
- [ ] Repomix 本地工具检测
- [ ] Gitingest 本地工具检测
- [ ] 「深度分析这个仓库」按钮
- [ ] 深度分析结果缓存
- [ ] 架构图 / 模块说明
- 已有方案：`docs/2-产品/需求讨论/agent/02-替代品推荐-Agent方案.md`（CodeFlow / Repomix / Gitingest / RepoLens / CodeBoarding / RepoMind 调研）

### §10.4(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 技术选型助手
- [ ] AI 设置页接入
- [ ] Search 页面「技术选型」模式
- [ ] 候选项目确认 UI
- [ ] AI 对比报告生成
- [ ] 报告保存与 Markdown 导出
- 已有方案：`docs/发展规划.md §4 技术选型助手`（已落档）

### §10.5(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 安全雷达：Star 项目漏洞监控
- [ ] OSV API 接入
- [ ] GitHub Global Security Advisories 接入
- [ ] manifest / lockfile 轻量扫描
- [ ] Security 页面
- [ ] 影响依据展示
- [ ] 漏洞忽略 / 稍后提醒
- 已有方案：`docs/发展规划.md §5 安全雷达`（已落档）/ `docs/2-产品/需求讨论/agent/11-安全与License风险-Agent方案.md`

### §10.6(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 项目健康度、维护活跃度与 License 风险
- [x] 项目健康度评分
- [x] OpenSSF Scorecard 安全评分
- [ ] License / Community Profile 检查
- [ ] 维护活跃度雷达
- [ ] Insights 页面
- 已有方案：`docs/发展规划.md §9 项目健康度` / `docs/需求讨论/Repo Health 项目健康度方案.md` / `docs/3-设计/详细设计/17-项目健康度与维护活跃度设计.md`（HOM-92 父任务）/ `docs/2-产品/需求讨论/agent/12-技术栈迁移-Agent方案.md`

### §10.7(详见 `docs/6-发版与上架/v1-上架信息准备.md`) Discover 轻量项目情报订阅
- [ ] GitHub Markdown feed source
- [ ] Markdown 中 GitHub URL 提取
- [ ] Discover 列表和来源管理
- [ ] 一键 Star / 稍后看 / 不感兴趣
- [ ] AI 摘要和推荐理由
- [ ] GitHub Search 定时任务
- [ ] 主题频道：Skill
- [ ] 主题频道：MCP
- [ ] 主题频道：AI Agent
- [ ] 主题频道：Local-first
- 已有方案：`docs/发展规划.md §7 热门项目推荐与轻量项目情报订阅`（已落档）

### §10.8(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 贡献机会发现
- [ ] Insights → Contribution Opportunities
- [ ] issue card
- 已有方案：`docs/发展规划.md §11 贡献机会发现`（已落档）

### §10.9(详见 `docs/6-发版与上架/v1-上架信息准备.md`) Apple Foundation Models 集成
- [ ] FM 可行性评估
- [ ] Starcat 对接 FM 功能矩阵
- [ ] FM 与 BYOK 双 Provider 切换
- 已有方案：`docs/2-产品/需求讨论/agent/01-Foundation-Models-可行性分析.md` / `docs/2-产品/需求讨论/agent/05-Apple-Foundation-Models-深度研究报告.md` / `docs/2-产品/需求讨论/agent/06-Starcat对接FM功能矩阵.md` / `docs/2-产品/需求讨论/agent/04-AgentRunKit-Swarm-SwiftAgent-对比分析.md`

### §10.10(详见 `docs/6-发版与上架/v1-上架信息准备.md`) 其它 Agent 方向（已有方案，待落地决策）
- [ ] Smart Collection 自动生成
- 已有方案：`docs/2-产品/需求讨论/agent/07-Smart-Collection-生成方案.md`
- [ ] Weekly Trending 解读
- 已有方案：`docs/2-产品/需求讨论/agent/08-Weekly-Trending解读方案.md`
- [ ] 替代品发现
- 已有方案：`docs/2-产品/需求讨论/agent/09-替代品发现-Agent方案.md`
- [ ] Release 影响分析
- 已有方案：`docs/2-产品/需求讨论/agent/10-Release影响-Agent方案.md`
- [ ] 重叠扫描
- 已有方案：`docs/2-产品/需求讨论/agent/11-重叠扫描-Agent方案.md`
- [ ] 回忆搜索
- 已有方案：`docs/2-产品/需求讨论/agent/12-回忆搜索-Agent方案.md`
- [ ] Untagged 批量整理
- 已有方案：`docs/2-产品/需求讨论/agent/13-Untagged批量整理-Agent方案.md`
- [ ] Unread 激活
- 已有方案：`docs/2-产品/需求讨论/agent/14-Unread激活-Agent方案.md`
- [ ] Agent 框架讨论记录与补充场景
- 已有方案：`docs/2-产品/需求讨论/agent/15-Agent框架讨论记录与补充场景.md` / `docs/2-产品/需求讨论/agent/00-概览-Agent方向讨论与方案.md` / `docs/2-产品/需求讨论/agent/03-Starred-Repo-周报-Agent方案.md` / `docs/2-产品/需求讨论/agent/10-Agent产品叙事-三条主线.md` / `docs/2-产品/需求讨论/agent/13-项目采用计划-Agent方案.md`

---

## §11 实施阶段（从 `docs/发展规划.md §13(详见 `docs/3-设计/详细设计/23-Chrome-插件方案.md`)`）

### §11.1 第一阶段：本地 AI 与单仓智能化（详情页具备 AI 理解能力）
- [x] AI 设置页：Provider、Base URL、API Key、模型、测试连接
- [x] `AIServiceProtocol` 与 OpenAI-compatible 最小实现
- [x] 单仓 AI 摘要
- [x] AI 标签推荐确认流
- [x] AI 结果本地缓存
- [x] 自动后台 AI 整理
- [x] README 翻译
- [x] AI 助手浮动窗口
- [x] AI 对话历史磁盘持久化
- [x] AnySearch 检索结果磁盘缓存
- [x] RepoContextPacker 客户端接入
- [x] Prompt 模块化重构

### §11.2(详见 `docs/功能实现总览.md`) 第二阶段：语义搜索与技术选型
- [x] Embedding 生成队列
- [x] 本地向量缓存
- [x] FTS5 + cosine similarity + RRF 融合
- [x] 向量搜索召回三段式增强
- [x] Search Center（Local + GitHub + AnySearch Web）
- [ ] Search 页面语义搜索
- [ ] 技术选型助手

### §11.3(详见 `docs/功能实现总览.md`) 第三阶段：Discover 轻量项目情报订阅
- [ ] GitHub Markdown feed source
- [ ] Markdown 中 GitHub URL 提取
- [ ] Discover 列表和来源管理
- [ ] 一键 Star / 稍后看 / 不感兴趣
- [ ] AI 摘要和推荐理由
- [ ] GitHub Search 定时任务
- [ ] 主题频道（Skill / MCP / AI Agent / Local-first）

### §11.4(详见 `docs/功能实现总览.md`) 第四阶段：安全雷达与项目健康度
- [x] 项目健康度评分
- [x] OpenSSF Scorecard
- [ ] License / Community Profile / Releases / Issues 指标
- [ ] OSV API / GitHub Advisory 集成
- [ ] manifest / lockfile 轻量扫描
- [ ] Security 页面
- [ ] 技术选型报告接入风险指标

### §11.5(详见 `docs/功能实现总览.md`) 第五阶段：深度项目分析
- [ ] Repomix / Gitingest 本地工具检测
- [ ] 「深度分析这个仓库」按钮
- [ ] 分析结果缓存
- [ ] 架构图 / 模块说明
- [ ] 技术选型深度模式

---

## §11.x UX 优化专项（v1 上架导向，2026-06-19）

### §11.x.1 UX 搜索 / 自动整理 / Pro 页优化
- [x] 非 Manage 页隐藏本地搜索入口
- [x] Search Center 筛选抽屉
- [x] 自动整理可操作状态入口
- [x] Pro 设置页购买决策卡

---

## 变更日志

| 日期 | 变更 |
|------|------|
| 2026-06-28 | 初版：从 `功能实现总览.md`（284 项）+ `v2-功能清单.md` + `发展规划.md §13(详见 `docs/3-设计/详细设计/23-Chrome-插件方案.md`)` + `docs/2-产品/需求讨论/agent/*` 聚合生成，全量覆盖 C 范围。 |
| 待更新 | 与 `功能实现总览.md` 同步刷新；源头变更后重新生成本文件。 |

---

*最后更新：2026-06-28*
