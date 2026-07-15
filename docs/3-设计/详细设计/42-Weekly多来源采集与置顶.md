# Weekly 多来源采集与置顶详细设计

> 状态：已实现，三轮专项审查通过
> 产品与架构单一方案：[`Weekly 多来源扩展、AI 情报采集与置顶运营正式方案`](../../2-产品/需求讨论/正式方案/Weekly多来源扩展与AI情报采集正式方案.md)
> 本文用途：记录代码落点、跨仓库契约和不可回退约束，不重复完整产品背景。

## 1. 实现边界

Weekly 继续由 `starcat-weekly-api` 聚合。首期固定来源为 `weekly / zread / discovery / hellogithub / ai_intelligence`；只有 `ai_intelligence` 允许管理 API 人工录入。Starcat 只读取公开 bulk，不持有或调用 `ADMIN_API_KEYS`。

后端事实真源为 `repo_source_events`。旧三源表只保留迁移和兼容读取证据，Collector 不再双写。新增来源必须先登记固定目录并完成客户端与运营入口，不能由请求动态创建。

## 2. 后端执行链

1. Collector、AI 情报导入把一批 `owner/repo` 写入 `ingest_batches + ingest_items`。
2. transaction commit 后通过容量为 1 的信号非阻塞唤醒 Worker。
3. Worker 启动扫描一次、信号到达时立即 drain、每 15 分钟兜底扫描。
4. Worker 在 SQLite transaction 外请求 GitHub API，成功后原子更新 `github_repos`、来源事件和 item。
5. 瞬时失败按 15/30 分钟退避；租约 30 分钟，最多尝试 3 次，永久失败或耗尽次数后剔除。
6. batch 进入终态时失效 bulk cache；置顶原子替换后也立即失效。

主要代码：

- `internal/ingest/service.go`、`wake.go`、`worker.go`
- `internal/store/migrations.go`、`ingest.go`、`ingest_worker.go`、`pins.go`
- `internal/handler/imports.go`、`hellogithub.go`、`pins.go`
- `internal/source/catalog.go`、`hellogithub.go`

## 3. HelloGitHub

- featured API 用于日常增量，受 `HELLOGITHUB_FEATURED_MAX_PAGES` 限制；
- periodical volume 页面用于历史回填与每月对账；
- 回填本身是带 `cursor_json.controller=true` 的持久化控制批次，每完成一期更新 `next_volume`；
- 子批次不能遮蔽仍在运行的 controller；`GET /internal/sources` 用 `latest_batch` 返回最新采集动作，用独立的 `active_backfill` 返回未结束的回填 controller；
- 服务启动和 15 分钟扫描都会恢复未完成回填，单期错误同样按 15/30 分钟重试并保留错误信息。

## 4. API 契约

公开客户端：

- `GET /api/v1/repos/bulk`：schema v2，返回 `sources / repos / languages`；repo 包含 `source_entries / is_pinned / pin_position`。
- `GET /api/v1/repos/{gh_repo_id}`：事件同时保留旧三源 payload 与通用 `source_code / source_url / title / summary / rank`。

管理端统一使用 `ADMIN_API_KEYS`：

- `GET /internal/sources`
- `POST /internal/sources/hellogithub/sync`
- `POST /internal/imports`
- `GET /internal/imports/{batch_id}` 与 `GET /internal/ingest-batches/{batch_id}`
- `GET /internal/repos/search`
- `GET /internal/pins` 与 `POST /internal/pins`

`POST /internal/imports` 返回 `202 Accepted` 后才由 Worker enrich；幂等键用于整批重放，批内按规范化 `owner/repo` 去重。置顶 POST 接收完整有序 `gh_repo_ids`，空数组表示清空。

## 5. Starcat 缓存与显示

- `WeeklySource` 为 raw-value 模型，未知来源不会导致 bulk 解码失败；
- bulk 来源目录存入 `weekly_bulk_sources`，通用条目和置顶字段由 `v11-weekly-multi-source` 追加迁移保存；
- 本地查询顺序固定为“筛选 → 置顶 → `pin_position` → 用户排序 → repo id”；
- 来源筛选由目录动态生成并显示 count；详情读取通用来源事件；
- HelloGitHub 与 AI 情报使用本地 SF Symbol resolver，未知来源回退 `questionmark.circle.fill`，不加载远程图标。

## 6. Skill 与本地控制台

`.claude/skills/starcat-weekly-import` 只负责文本解析、搜索核验、用户确认和整批提交。脚本默认 dry-run，只有显式 `--confirm` 才提交，不记录 admin key。

`pages/_local-admin` 的 Weekly 卡片展示来源数、队列、最近成功/失败、活动回填进度，并提供 HelloGitHub 同步与有序多项目置顶。页面刷新时优先从 `active_backfill` 恢复未完成历史回填；没有活动回填时才读取 `latest_batch` 展示最近采集动作，不依赖旧页面内存。

## 7. 验证基线

- weekly-api：`go test ./...`、`go test -race ./...`、`go vet ./...`、`go build ./...`；
- Starcat：`xcodegen generate` 后执行完整 `xcodebuild ... test`；
- local-admin：JavaScript 静态检查，并以 mock weekly-api 在真实浏览器验证来源状态、回填恢复、搜索、置顶调序、保存后刷新和缺少 admin key 提示。

专项 checklist、逐轮审查和最终结果统一存放在 `docs/4-工程进度/Weekly多来源采集专项/`。
