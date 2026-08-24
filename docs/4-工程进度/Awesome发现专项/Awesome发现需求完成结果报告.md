# Awesome 发现需求完成结果报告

- 完成日期：2026-08-24
- 开发分支：原专项分支已合入；本轮按 dong4j 要求直接提交到主仓库、`starcat-discovery-api` 和聚合 `starcat-api` 的本地 `dev`
- 关联任务：[#109](https://github.com/starcat-app/Starcat/issues/109)
- 完成状态：双描述来源卡片、来源仓库元数据与语言分布、主动刷新和时间迁移修复已完成；20 轮审查通过，本轮 Discovery API 增量待单独授权部署，客户端待人工 UI 验收

## 项目目标

在现有“探索”三栏中新增 Awesome 模式：内置来源由 Discovery API 与内容管理后台维护，用户首次进入时选择来源，也可添加只保存在当前账户本地的自定义来源；中栏展示 README 解析出的 GitHub Repo，右栏复用统一详情并保留来源证据。

## 完成内容与功能清单

### Discovery API

- 追加 Awesome 来源、条目、同步运行表及安全的增量 schema 升级。
- 实现来源 CRUD、revision 并发控制、同步、发布、下架和 sync-runs 恢复。
- 使用 CommonMark/GFM AST 解析 README，完成 GitHub Repo 归一化、GitHub API enrich、幂等同步和失败保留旧快照。
- 提供精选来源目录和单来源 entries 公共 API，支持 ETag/304、稳定排序和准确快照时间。
- `source_stars` 为目录 API 必返字段；服务端从 GitHub Repo 元数据读取真实 Stars，不以 `0` 或“未知”掩盖缺失数据。
- 来源目录返回 `repo_description`，直接复用共享 `repos.description` GitHub 真值，不在来源内容表重复维护。
- 来源目录增加 Forks、Watchers、Subscribers、Issues、主要语言和 `language_bytes`；语言分布只抓取 Awesome 来源仓库，并持久化到独立 `awesome_source_languages` 表。
- entries 补齐 Stars、forks、watchers、subscribers、open issues、主页、默认分支、license、topics、fork/archive 以及创建、推送、更新时间。
- 增加 `repo_metadata_version`：旧库只清除一次历史成功 SHA，使下一次同步强制 enrich；成功后继续按 README SHA 复用缓存，避免每次重复解析和请求 GitHub。
- SQLite 作为跨重启持久快照；公开响应增加 JSON/gzip/ETag 有界 LRU，最多 64 条 / 64 MiB，并合并同 key 并发 miss。
- 来源 CRUD、同步、发布和下架精确失效目录/来源响应缓存，失效代际阻止旧的在途构建重新写回。

### 本地运营后台

- 增加精选来源列表、新增/编辑、稳定排序、同步、发布和下架操作。
- 展示来源状态、仓库/外部条目计数、同步结果和稳定错误码。
- Admin key 仅由本地受限代理注入，不进入页面表单和日志。

### Starcat 客户端

- 追加 `v22-awesome-discovery`、`v23-awesome-source-metadata`、`v24-awesome-cache-freshness`、`v25-awesome-source-stars-refresh`、`v26-awesome-repository-metadata`、`v28-awesome-source-description`、`v29-awesome-source-card-metadata` 和 `v30-awesome-entry-updated-at`，未修改已发布 `v1-initial`。
- 实现 API DTO、ETag/304、账户隔离 SQLite 缓存、SWR 刷新、下架降级与失败保留旧条目。
- 精选目录和每个来源条目使用独立 6 小时 freshness；自动进入复用新鲜缓存，手动刷新绕过 freshness，`304` 推进检查时间。
- v25 使历史零 Stars 目录缓存立即失效；来源 DTO 将 Stars 设为必返，错误数据不会继续显示为批量 `0`。
- v26 将完整 Repo 事实保存到 Awesome 条目缓存，并映射至统一 Repo 列表和右栏详情 Hero。
- 自定义来源只从 Starcat 客户端调用 GitHub API、解析 README 并写当前账户本地库，不上传 Discovery API。
- Awesome 位于“探索 → 周刊”下方；与周刊状态隔离，管理入口位于 Awesome 名称右侧。
- 首次进入自动打开来源 Sheet；Sheet 固定三列，Repo 风格卡片使用真实 Stars、项目数与状态胶囊，整卡可点击且高度稳定。
- Sheet 增加左上角 Awesome 图标、搜索框和搜索空态；卡片优先展示 GitHub 官方 description，并增加 Logo 采样渐变与独立 GitHub 跳转按钮。
- Sheet 初次打开不自动聚焦输入框；标题使用 Awesome 品牌图标；来源卡片固定高度并分别展示 GitHub description 与 Discovery 内容管理摘要。
- 来源卡片增加 Stars、Forks、Watchers、Issues、解析项目数和主要语言多色色条，继续保留 Logo 取色渐变与系统语义文字色。
- Sheet 刷新只强制校验来源目录；中栏刷新同时校验目录和已启用来源条目，均复用 `SyncIconButton`。
- v30 为早期开发库补齐 `repo_updated_at` 并失效 managed entries ETag，下一次成功刷新自动回填详情创建与更新时间。
- 来源图片依次使用内容管理图片、GitHub owner avatar 和 Awesome SF Symbol；侧边栏复用同一 Logo 回退策略。
- 自定义输入区标题为“新增 Awesome 项目”，不显示“仅在本机解析，不会上传到 Discovery”的冗余说明。
- 自定义来源点击“添加”后立即保存并启用；失败在输入区展示明确原因，不再出现无反馈或二次确认。
- 来源点击同步更新高亮，旧加载任务取消并执行 sourceID 代际校验，快速切换不会被晚返回结果覆盖。
- 中栏支持全部/单来源、章节、搜索与四种排序；按 `gh_repo_id` 去重并保留多来源证据。
- 右栏复用 Repo 详情并以当前 Discovery entries 公共元数据为准，展示 forks、watchers、subscribers、issues、创建/推送/更新时间、默认分支、license、topics 和来源证据。

## 文档同步情况

- 正式方案已与最终 API、schema、缓存、完整 Repo 字段、三列来源 UI 和自定义来源本地边界对齐。
- 专项 Checklist、人工 UI 验收清单和第 1 至第 20 轮审查报告已同步。
- Discovery API 中英文 API 文档与本地运营后台交互已同步。
- `docs/功能实现总览.md` 仅做只读检查，因未获得专门写入授权而保持不变。

## 测试情况

- Starcat：本轮 `xcodebuild test` 全量 2604 项、303 个 suites 通过，1 个 known issue、0 个失败；Awesome API、Repository、Store 与迁移定向测试均通过。
- Discovery API：本轮 `go test ./...`、`go vet ./...` 和 `go test -race ./internal/github ./internal/awesome ./internal/store ./internal/handler` 通过。
- 聚合 `starcat-api`：`go test ./...` 共 `11` 个测试通过；`go vet ./...` 通过。
- 静态门禁：三仓库 `git diff --check`、本地化 Catalog JSON 解析和新增 Awesome UI 规范检查通过。
- Starcat 测试中仍有 `DiagnosticsTests.swift` 的 4 条既有 Swift Concurrency runtime warning；测试均通过，告警与本轮 Awesome 差异无关。
- 生产部署：Fly `starcat-api` Release v10、Machine 健康检查和六个聚合服务 ping 全部通过；生产 Volume 已在部署前创建快照。
- 生产数据：`awesome-mac`、`awesome-design-patterns`、`awesome-python` 分别刷新 285、29、475 条；基础数值、默认分支与三个时间字段缺失数均为 0。

## 审查轮次

1. 第 1 至第 3 轮：完成原需求交付的文档、代码、测试和最终排序一致性审查。
2. 第 4 至第 7 轮：完成生产状态、来源 Stars、卡片元数据和快速切换验收修复审查。
3. 第 8 至第 10 轮：完成客户端 freshness、服务端有界响应缓存和双层缓存文档一致性审查。
4. 第 11 轮：发现并修复旧 README SHA 快照无法自动补齐新增 Repo 元数据的问题，同时修正文档字段与三列 UI 契约。
5. 第 12 轮：完成三仓库全量测试、race、vet、迁移安全、缓存边界和代码质量审查，未发现新增问题。
6. 第 13 轮：完成最终文档、Issue 状态、三仓库清洁度、本地化 Catalog 和 UI 静态规范终审，未发现新增问题。
7. 第 14 轮：完成生产 Volume 快照、聚合 API v10 部署、六服务健康检查和三个验收来源完整元数据回填，未发现发布阻断问题。
8. 第 15 轮：审查来源添加、`repo_description`、Sheet 搜索、Logo 取色卡片和详情元数据链路，发现并修复固定白色图标与空 description 回退问题。
9. 第 16 轮：完成最终代码、文档、测试、迁移安全和工作区清洁度终审，未发现新增遗留问题。
10. 第 17 轮：完成生产快照、聚合 API v11 部署、六服务健康检查和 84 条来源真实描述验证，未发现发布阻断问题。
11. 第 18 轮：发现来源卡片仅设置最小高度仍可能随双描述变化，修复为固定高度并完成增量构建。
12. 第 19 轮：完成架构影响、并发安全、双层缓存、迁移与文档一致性复审，未发现新增代码问题。
13. 第 20 轮：完成最终提交、全量测试、工作区隔离、发布权限和结果报告终审，无遗留代码问题。

全部报告均保存在本专项目录的 `审查报告/` 下。

## 本地提交

- 本轮主仓库功能提交：`fed156d`（自定义来源立即生效）、`5b792c6`（真实描述缓存与 v28）、`bd59a1d`（搜索与标题图标）、`01b4e9c`（Logo 取色卡片与 GitHub 跳转）、`b1613d0`（详情元数据）、`785f931`（终审修复）。
- 本次增量主仓库提交：`2381320d`（取消初始聚焦）、`69437e3a`（品牌图标）、`b5ba6802`（来源元数据缓存）、`ca9bb878`（双描述卡片）、`b2bb9e9b`（刷新入口）、`9b2e55a7`（时间迁移）、`ff1e0fb0`（固定高度）和 `9095a90b`（文档同步）。
- Discovery API 本轮功能提交：`ae65296`（目录返回来源仓库真实描述）；此前 `3985832`、`72a07a5` 继续负责完整 Repo 元数据与历史快照回填。
- Discovery API 本次增量提交：`ac68064`（来源 Languages API）与 `57ecec1`（目录元数据和语言持久缓存）。
- 本轮文档与审查提交：`938566b3`、`8beb3024`、`a423b0d` 及最终文档收口提交。
- 聚合 `starcat-api` 直接复用本地 Discovery module，没有为相同源码制造空提交。
- 所有 commit 仅保存在本地，未 push。

## 遗留问题与后续门禁

- Awesome 本轮代码遗留问题：无。
- 本次 Discovery API 增量尚未部署生产；需 dong4j 单独确认后部署聚合 API、触发 published 来源同步并验证 `language_bytes` 与新增指标。
- 生产部署：`ae65296` 已随聚合 API v11 上线；目录 84 条来源均返回非空 `repo_description`，Stars 零值数量为 0。
- 生产聚合 API 已部署；其余 published 来源由每 3 小时定时任务执行一次性元数据回填和后续 README SHA 增量刷新。
- 人工 UI 验收：待 dong4j 按 [`人工UI验收清单.md`](./人工UI验收清单.md) 执行；自动化测试不替代人工验收。
- Issue #109：保持 Open；第 13 轮完成后进入 Project `Acceptance`，仅在 dong4j 明确验收通过后关闭。

## 全局工程总览候选文本

> 以下仅为候选，本次未写入 `docs/功能实现总览.md`。

```markdown
- [x] **Awesome 发现与来源管理** — 探索新增 API 驱动的 Awesome 来源、README 解析与三栏浏览 — `Starcat/Features/Explore/AwesomeView.swift` — 2026-08-24
> 实现：精选来源由 Discovery API 与本地运营台维护，自定义来源在账户数据库本地解析；完整 GitHub 元数据进入统一详情，按 Repo ID 去重并保留来源证据，三列来源管理、双层缓存与失败降级均已完成，人工 UI 验收见专项清单。
- 2026-08-24 19:20: 完成 Awesome 完整仓库元数据、三列来源管理与双层缓存
```

## 最终完成状态

本地代码、专项文档、自动化测试和 20 轮审查均已完成，审查问题全部修复；此前生产聚合 API v11 已通过真实描述与六服务健康验证，本次语言分布和来源指标增量待单独授权部署，客户端交付 dong4j 人工 UI 验收。
