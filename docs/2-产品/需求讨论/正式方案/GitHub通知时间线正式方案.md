# GitHub 通知时间线正式方案

> 日期: 2026-08-19
> 状态: 实施中
> 范围: 活动页「通知」时间线、本地回填与增量同步、选中后补全详情、异步把 GitHub thread 标已读、高信号系统通知
> 不包含: 用户自己的 Push/Star 事件账本、GitHub Notifications 收件箱以外的 Events API、`repo` scope、CloudKit 同步已读、改 `docs/功能实现总览.md`（实施完成并经 dong4j 确认后再登记）

讨论拍板（2026-08-19）：

1. 数据源是「别人对当前用户做的事」，走 `GET /notifications`，不是 `/users/{login}/events`。
2. 首次最多回填约 300 条，记下水位；上线后本地已有历史，不是空列表。
3. 中栏只用通知接口字段；选中后再懒加载请求人与摘要。
4. 选中后蓝点先灭；400ms 内划走则恢复且不 PATCH；停满后再异步 `PATCH` GitHub thread。
5. 入口放在活动左栏，中栏做时间线，不用仓库卡片。

---

## 1. 方案结论

在活动页新增独立分类「通知」：一条按时间分组的 inbox 时间线，记录 GitHub 通知 thread（被 @、被指派、被 request review、安全公告等）。

- 首次登录或本功能首次同步：`all=true` 翻页入库，上限 300 条，立刻可刷。
- 之后只拉水位之后的更新，按 thread id upsert。
- 单击一行：选中并打开右栏；不离开 App。跳 GitHub 只走右栏主按钮或行上外链。
- 右栏先画本地骨架，再对这一条 `subject.url` 打 1 次请求补全。
- 选中后蓝点先灭；若 400ms 内划走则蓝点恢复且不 PATCH。停满 400ms 才后台 PATCH GitHub thread，失败不挡 UI。

这是独立产品面，与活动「关注」（`received_events`）和 Release 订阅通知并列，不合并成一条 feed。

---

## 2. 背景与现状

现有活动页是仓库卡片聚合：公告、发行版、星标、仓库、关注、建议。关注走 `GET /users/{username}/received_events/public`，语义是「我关注的人在公开仓库干了什么」，表为 `activity_events`。

用户要的是「发生在我身上的 GitHub 通知」，官方对应 Notifications API。该 API 为轮询设计（`Last-Modified` / `If-Modified-Since` / `X-Poll-Interval`），Events API 明确不适合当实时通知源。

现成可复用：

- 活动三栏壳：`ActivityCategory`、`ActivityView`、`ActivityDetailView` 的 non-repo 详情分支。
- 通知派发：`AppNotificationService` + `settings.notificationsEnabled`。
- 后台节奏：`NSBackgroundActivityScheduler`，现有 poller 均为 interval ≥ 30 min。
- Events 解析经验：payload 异构、ETag、本地 TEXT 主键。通知 thread 比 Event 更规整，仍单独建表。

不能复用：

- `activity_events`：数据源、actor、过滤 `ReleaseEvent`、已读语义都不同。
- `UnifiedRepoRow`：通知不是以仓库为主体。
- 当前 OAuth：`read:user` + `public_repo`（代码里还有 `user`）读不到通知 inbox，也 PATCH 不了 thread。

---

## 3. 产品目标

### 3.1 必须实现

- 活动左栏出现「通知」，带本地未读角标。
- 打开分类即可看到最多约 300 条历史 thread，按今天 / 昨天 / 本周 / 更早分组。
- 中栏是时间线行：reason chip、标题、仓库与编号、相对时间、未读点。无人名、无评论摘录。
- 顶部分段：全部 / 未读 / Mention / Review（均在「通知」分类内过滤）。
- 单击选中；右栏展示类型+编号、仓库、reason、时间、主按钮「在 GitHub 打开」；若该仓库已在本地库中，再给「在 Starcat 中查看」。
- 选中后异步补全请求人与摘要；失败时骨架仍可用。
- 选中后蓝点先灭；400ms 内划走则恢复未读且不 PATCH；停满后再异步把 GitHub thread 标已读。
- 高信号新 thread 发 macOS 系统通知；点击通知打开 App 并选中对应行。
- 缺少 `notifications` scope 时，给出重新授权入口，而不是空白失败。

### 3.2 本期不做

- 不把通知混进活动「全部分类」的仓库卡片流（与 Undo Star 一样，独立分类）。
- 不回填 300 条时补全人名 / 摘录 / 相关人员。
- 不做右栏关闭、上一条 / 下一条、相关人员头像墙。
- 不申请 `repo` scope；私仓通知能显示多少算多少。
- 不调用「全部标已读」接口。
- 不把已读、摘录缓存同步到 CloudKit。
- 首次回填的历史条目不发系统通知。
- 不承诺实时；UI 必须显示上次同步时间。

---

## 4. GitHub API 与权限

### 4.1 端点

| 用途 | 方法 | 路径 | 说明 |
|---|---|---|---|
| 列表 / 回填 / 增量 | `GET` | `/notifications` | `all=true`，`per_page=50`（官方上限 50） |
| 标已读 | `PATCH` | `/notifications/threads/{thread_id}` | 成功一般为 205；只标这一条 |
| 补全详情 | `GET` | `subject.url` | 选中后 1 次；Issue / PR 的 subject.url 通常是 issues 资源 |

禁止：`PUT /notifications`（mark all）、对回填结果批量 PATCH。

查询约定：

- 首次回填：`all=true`，跟 `Link` 翻页，累计满 300 或没有下一页即停。
- 增量：`all=true` + `since={watermark}`，请求头带上次的 `If-Modified-Since`。304 则不改库、不耗业务逻辑。
- 遵守响应头 `X-Poll-Interval`（常见 ≥ 60 秒）。客户端调度仍 ≥ 30 分钟，与 Release poller 同档，取两者较大值。

水位同时记：

1. 响应头 `Last-Modified`（给下一轮 If-Modified-Since）。
2. 本地已入库 `max(updated_at)`（给 `since=`，防止头丢失）。

### 4.2 通知 JSON 能直接用的字段

`id`（thread id，字符串）、`unread`、`reason`、`updated_at`、`repository.full_name` / `repository.id`、`subject.title` / `subject.type` / `subject.url`。

没有：actor login、评论 body、PR 摘要、html_url、相关人员。这些只能在选中后从 `subject.url` 补。

`reason` 与中栏 chip / 筛选的对应：

| GitHub `reason` | 中栏 chip | 分段「Mention」 | 分段「Review」 | 默认系统通知 |
|---|---|---|---|---|
| `mention` / `team_mention` | Mention | 是 | 否 | 是 |
| `review_requested` / `review_submitted` | Review | 否 | 是 | `review_requested` 是，`review_submitted` 否 |
| `assign` | Assign | 否 | 否 | 是 |
| `security_alert` | Security | 否 | 否 | 是 |
| `comment` / `author` / `state_change` / `subscribed` / `manual` / `ci_activity` / `invitation` / 其它 | Comment 或按 type 映射的安静标签 | 否 | 否 | 否 |

`subject.type` 用于拼编号与 GitHub Web URL（补全成功前的降级）：

| type | 路径 |
|---|---|
| `PullRequest` | `https://github.com/{full_name}/pull/{n}` |
| `Issue` | `https://github.com/{full_name}/issues/{n}` |
| `Release` | `https://github.com/{full_name}/releases`（有 html_url 则用之） |
| `Discussion` | `https://github.com/{full_name}/discussions` |
| `Commit` | `https://github.com/{full_name}/commit/{sha}`（从 url 末段取） |
| 其它 | `https://github.com/{full_name}` |

编号 `{n}` 从 `subject.url` 最后一段解析；解析失败则次行不显示编号。

### 4.3 OAuth

实施时把 `notifications` 加进实际授权列表 `Constants.githubOAuthScopes`（当前为 `read:user` / `public_repo` / `user`），并同步改 `docs/2-产品/需求讨论/正式方案/GitHub OAuth 设计.md` §2.1。三种登录方式共用同一份 scope。

已登录用户 token 没有该 scope：`GET /notifications` 会 403。空态文案说明原因，主按钮走现有重新授权（Device / Web / PAT 指引补 scope）。不静默失败。

响应头 `X-OAuth-Scopes` 可在一次成功或失败的 GitHub 请求后缓存，用于设置页提示，但功能入口仍以真实 403 为准。

不加 `repo`。私有仓库 thread 可能 404 或缺字段；列表仍显示 title / repo / reason，右栏补全失败则只留「打开 GitHub」。

---

## 5. 数据模型

已发布库只追加 `registerVN`，不改 `v1-initial`。实施时用当时 migrator 的下一个版本号（本文撰写时最新为 `v20-rag-chunks-fts-trigram`）。

### 5.1 `github_notification_threads`

thread 缓存。`id` 用 GitHub thread id（TEXT PK）。

| 列 | 类型 | 含义 |
|---|---|---|
| `id` | TEXT PK | GitHub thread id |
| `reason` | TEXT NOT NULL | 如 `mention` |
| `unread` | BOOLEAN NOT NULL | 本地展示用未读；选中后立刻 false |
| `github_unread` | BOOLEAN NOT NULL | 上次从 GitHub 看到的 unread，用于失败校准 |
| `repository_id` | INTEGER | GitHub repo id，可空 |
| `repository_full_name` | TEXT NOT NULL | `owner/repo` |
| `subject_title` | TEXT NOT NULL | |
| `subject_type` | TEXT NOT NULL | `Issue` / `PullRequest` / … |
| `subject_api_url` | TEXT NOT NULL | 补全用 |
| `subject_number` | INTEGER | 解析出的编号 |
| `html_url` | TEXT | 补全得到或本地拼出的降级 URL |
| `actor_login` | TEXT | 选中补全后的请求人 / author |
| `excerpt` | TEXT | 选中补全后的截断摘要 |
| `hydrated_at` | TEXT | 补全成功时间；有值则再选中不重复打 |
| `updated_at` | TEXT NOT NULL | GitHub thread `updated_at` |
| `first_seen_at` | TEXT NOT NULL | 本机首次入库 |
| `notified_at` | TEXT | 已发过系统通知则写入，防重复 |
| `mark_read_state` | TEXT NOT NULL | `idle` / `pending` / `synced` / `failed` |
| `fetched_at` | TEXT NOT NULL | 本轮同步写入时间 |

索引：`updated_at` 降序（主列表）、`unread`、`reason`。

Upsert 键：`id`。同一 thread 再更新：刷新 `updated_at` / `reason` / `subject_*` / `github_unread`；**不覆盖** `first_seen_at`、`excerpt` / `actor_login` / `hydrated_at`（除非 `subject_api_url` 或 `updated_at` 变了，此时清掉补全缓存以便再选中拉新摘要）。若 GitHub `unread=true` 且本地 `mark_read_state != pending`，把本地 `unread` 拉回 true（GitHub 仍未读则以 GitHub 为准）。本地刚乐观已读且 `pending`/`synced` 时，增量结果里的 `unread=true` 不立刻打回蓝点，等 PATCH 失败校准。

### 5.2 `github_notification_sync_state`

单行，PK 固定 `singleton`。

| 列 | 含义 |
|---|---|
| `last_modified` | 上次列表响应的 Last-Modified |
| `watermark_updated_at` | 本地 `max(updated_at)` |
| `last_fetched_at` | 上次成功拉列表 |
| `backfill_completed_at` | 首次 300 回填完成；空表示还在首次回填，禁止发系统通知 |
| `last_poll_interval_seconds` | 记录 GitHub 给出的 X-Poll-Interval |

不把 ETag 塞进 `activity_sync_state`，避免和 following events 生命周期缠在一起。

已读、摘录、`notified_at` 均为本机数据，不进 CloudKit。GitHub 已读一旦 PATCH 成功，其它设备下次拉通知自然对齐。

---

## 6. 同步与通知策略

### 6.1 首次回填

条件：`backfill_completed_at` 为空。

1. `GET /notifications?all=true&per_page=50` 翻页。
2. 写入 / upsert，计数到 300 停止。
3. 写 `last_modified`、`watermark_updated_at`、`backfill_completed_at`、`last_fetched_at`。
4. **不**发 macOS 通知，**不** PATCH 任何 thread。

手动刷新与后台 poller 共用同一套函数；首次未完成时只走回填，不走增量。

### 6.2 增量

`backfill_completed_at` 已有值之后：

1. 带 `since` + `If-Modified-Since`。
2. 304：只更新 `last_fetched_at`。
3. 200：upsert 返回的 thread；刷新水位。
4. 对「回填完成后新出现或 `updated_at` 超过上一轮水位、且 `github_unread=true`、且 reason 在默认系统通知表、且 `notified_at` 为空」的行发系统通知，然后写 `notified_at`。
5. identifier：`github-notif-{threadId}`，点击打开 App 并选中该行，再走与单击相同的停留 + PATCH。

系统通知开关：总开关 `notificationsEnabled` + 新开关 `githubInboxNotificationsEnabled`（默认开）。默认 reason 固定为 mention / team_mention / assign / review_requested / security_alert，v1 不做 per-reason 设置页。

### 6.3 后台节奏

新的 `GitHubNotificationPoller`，`NSBackgroundActivityScheduler`。调度间隔取 30 分钟与 GitHub `X-Poll-Interval` 的较大值（后者通常 ≥ 60 秒，因此实际下限仍是 30 分钟）。`requiresNetworkConnectivity=true`。与现有 poller 一样防重入。测试期用 `TestEnvironment.isRunning` 跳过调度，不弹授权框。

前台进入「通知」分类或点刷新：立刻拉一次，仍走 If-Modified-Since / 304 与回填闸门。

### 6.4 选中：补全与标已读（并行、不阻塞 UI）

选中一行时同时丢两个后台任务，UI 只等本地状态：

**任务 A — 补全**

- 若 `hydrated_at` 非空且 `subject_api_url` 未变：直接用缓存。
- 否则 `GET subject.url`。成功则写 `actor_login`（user.login 或 requested_reviewers 不可得时退到 user.login）、`excerpt`（body 截到约 500 字）、`html_url`、`hydrated_at`。
- 404 / 403 / 超时：右栏保持骨架，主按钮仍用降级 URL。

**任务 B — 标已读**

1. 选中当下：本地 `unread=false`，角标减一，`mark_read_state=pending`，启动 400ms 计时。
2. 400ms 内改选其它行：本行取消 PATCH，本地 `unread` 恢复 true，`mark_read_state=idle`，角标加回。
3. 停满 400ms：发出 `PATCH /notifications/threads/{id}`。成功则 `mark_read_state=synced` 且 `github_unread=false`。失败则 `mark_read_state=failed`，本地保持已读不闪回，进入失败队列，下次增量结束后重试一次。
4. 本地已是 `unread=false` 且 `mark_read_state=synced` 的行不再 PATCH。
5. 禁止对停留不足的行发 PATCH。禁止 mark-all。

键盘连续移动时每行各自计时，划过的行打不到 GitHub。

---

## 7. UI

气质遵循根目录 `DESIGN.md`：Mail / Finder 密度，系统色，8px 圆角，选中 `#EAF3FF`（实际用 `Color.accentColor.opacity(0.12)`）。reason chip 用安静 `MetaBadge` 风格，不要六色彩虹。Security 可用危险色，因为它是状态不是装饰。

### 7.1 左栏

`ActivityCategory` 增加 `notification`。文案 key：`activity.category.notification`。图标用现有分类色点规则，不引入语言图标。未读数来自本地 `unread=true` 计数。

不进入「全部分类」聚合。

### 7.2 中栏

新 row 组件，不走 `UnifiedRepoRow`。

- 顶栏：标题「通知」+ 条数；分段全部 / 未读 / Mention / Review；`SyncIconButton`；caption「上次同步 …」。
- 日期分组：今天 / 昨天 / 本周 / 更早（按 `updated_at` 本地日历）。
- 行高约 56–64pt。左侧细线 + 圆点（未读 accent，已读 secondary）。
- 主行：`subject_title`（`.subheadline.weight(.semibold)` / 15pt）。
- 次行：`full_name · PR #n · 相对时间`（caption）。不要时钟 `14:32`。
- 右侧 reason chip。
- 行尾可放小外链图标，点击 `NSWorkspace` 打开 `html_url`（无则降级 URL），不改变选中与已读计时。
- 整行单击：选中。`.buttonStyle(.plain)` 必须 `.focusEffectDisabled()`。
- 空态：未登录 / 缺 scope / 回填中 / 真的零通知，文案分开。

### 7.3 右栏

走 `ActivityDetailView` non-repo 分支，不要 README shell。

立刻显示：`subject_type` + 编号、仓库、reason、相对时间 + 绝对时间、主按钮「在 GitHub 打开」、条件按钮「在 Starcat 中查看仓库」（`repository_id` 能命中本地 `repos` 才出现）。

补全成功后追加：请求人、摘要。没有关闭按钮，没有上下一条。

主按钮始终可点；补全前用拼出的 URL，补全后换官方 `html_url`。

### 7.4 系统通知点击

`userInfo` 带 `threadId`。`HomeView` 切到活动 → 通知分类 → 选中该 id。随后走第 6.4 节同一套停留 + PATCH。

---

## 8. 模块落点（实施时）

| 层 | 拟定路径 | 职责 |
|---|---|---|
| 迁移 | `DatabaseMigrationsV1.swift` 追加 `registerVN` | 两张新表 |
| 模型 / 仓储 | `Starcat/Core/Database/Models/` + `Starcat/Core/Sync/` | thread 与 sync_state |
| 网络 | `AppEndpoints` + `GitHubAPI/` 新 Notifications API | 列表、PATCH、透传 subject GET |
| 同步 | `GitHubNotificationPoller` + 回填/增量 UseCase | 调度、水位、系统通知闸门 |
| 通知 | `AppNotificationService` 增 inbox dispatch | 与 Release 共用 dispatcher |
| 设置 | `AppSettings` + 设置页通知区 | `githubInboxNotificationsEnabled` |
| OAuth | `Constants.githubOAuthScopes` | 加 `notifications` |
| UI | `ActivityModels` / `ActivityView` / 新 Timeline row / `ActivityDetailView` | 分类、列表、详情 |
| 导航 | `HomeView` / 通知点击 | 定位到 thread |
| 测试 | `StarcatTests/` 新 suite | 见第 9 节 |
| 文档 | `GitHub OAuth 设计.md` §2.1 | 实施时同步 scope |

i18n 只在 `Localizable.xcstrings` 用相邻 key 手工加，禁止整文件格式化、禁止脚本改 Catalog。

---

## 9. 测试

命令行测前关掉 Xcode IDE。新增 Swift 文件后先 `xcodegen generate`。启动期不碰 Keychain：poller / 授权请求必须 `TestEnvironment.isRunning` 门控。

必须覆盖：

- 解析列表 DTO（含缺 number、未知 reason、未知 subject type）。
- 回填在 300 条停止，且不发系统通知、不 PATCH。
- 同一 id upsert 更新 `updated_at`，保留 `first_seen_at`。
- 304 不改 thread 表。
- 选中 400ms 内离开：不 PATCH，本地未读恢复。
- 停满 400ms：PATCH 一次；已读行不再 PATCH。
- 从不调用 mark-all。
- `hydrated_at` 已有则不二次 GET；url 变化则重拉。
- 缺 scope / 403 映射到重新授权空态。
- 系统通知 identifier 去重；回填完成前 `notified_at` 保持空。

---

## 10. 失败与回滚

| 情况 | 行为 |
|---|---|
| GitHub 延迟 / 5xx | 列表仍用本地；顶栏显示上次成功同步时间 |
| 缺 scope | 空态 + 重新授权，不清已入库数据 |
| 补全 404 | 右栏骨架 + 降级 URL |
| PATCH 失败 | 本地已读保持；`failed` + 重试 |
| 用户关掉功能 | 停 poller、停系统通知；表保留 |
| 方向错误要撤 | 隐藏分类、停 poller、scope 可留（再授权成本高，不强制从 token 拿掉） |

回滚不删用户库里的两张表。

---

## 11. 与既有决策的边界

- 活动关注继续只用 `received_events/public` + `activity_events`。本功能不往那张表写。
- Release 系统通知继续走 `ReleaseMonitor` / `releaseNotificationsEnabled`。通知时间线里的 `Release` subject 只作为 inbox 一行，不替代订阅轮询。
- AI 保守策略与本功能无关：不自动改 tag / note。
- 正式版 schema：只追加 `registerVN`。

---

## 12. 验收标准

1. 新用户（已重新授权）打开「通知」，无需等待增量轮，能看到最多 300 条历史（若 GitHub 侧不足 300 则以实际为准）。
2. 中栏无人名、无摘录；右栏选中后出现请求人或摘要，或明确保持骨架。
3. 快速划过列表，GitHub.com 通知未读不被批量清掉；停在一行约 400ms 后，该 thread 在 GitHub 变为已读。
4. 首次回填不弹系统通知；回填完成后的新 mention / assign / review_requested / security_alert 会弹。
5. 点击系统通知或「在 GitHub 打开」能到达正确页面 / 正确行。
6. 未授权 `notifications` 时有重新授权，而不是无限转圈。
