# Activity 公告与关注 — 数据接入方案

> 状态：v2 方案讨论完成，待 dong4j 明确「开干」指令
> 日期：2026-06-16
> 版本历史：
> - v1（2026-06-16 早）：首版讨论稿
> - v2（2026-06-16 晚）：dong4j 拍板 6 个决策（Q1/Q2/Q3 + P5 + M2 + M3）+ 6 个技术细节（P1~P4/P6），整文档重写

---

## 一、现状

`ActivityViewModel.makeItems` 目前只产出 5 种卡片：

| Builder | 分类 | 数据源 | 实际内容 |
|---------|------|--------|----------|
| `makeAnnouncement()` | announcement | ❌ 一条硬编码占位 | "Activity v1 已上线" |
| `makeReleaseItems()` | release | ✅ `ReleaseRepository.fetchTimeline` | 真实 Release |
| `makeStarItems()` | star | ✅ `RepoRepository.fetchAllStarred` | 真实 Star |
| `makeRepositoryItems()` | repository | ✅ `RepoRepository.fetchAllStarred` | 真实 Push |
| `makeSuggestionItems()` | suggestion | ✅ `RepoRepository.fetchAllStarred` | 启发式推荐 |
| **不存在** | **following** | ❌ 无 builder | 永远空列表 |

两个空分类需接入真实数据。

---

## 二、数据源方案

### 2.1 following — GitHub Events API

```
GET /users/{username}/received_events/public
```

- 无需新 OAuth scope（公开事件，`read:user` 已够）
- 一个请求拿到当前用户关注的所有人的聚合事件流
- 单次返回最大 300 条，仅 30 天内
- REST API，JSON 格式
- **支持 ETag / If-None-Match → 304 短路**，必须用上（项目里 `sync_state.stars_etag` 同款模式）

**纳入 following 的事件类型**（dong4j 2026-06-16 决策 Q1：**过滤 ReleaseEvent**，与 `releases` 表完全解耦避免双显）：

| Event 类型 | 含义 | 关键 payload 字段 |
|-----------|------|------------------|
| `WatchEvent` | 某人 star 了仓库 | `action: "started"` |
| `ForkEvent` | 某人 fork 了仓库 | `forkee`（含完整 fork 仓库信息） |
| `CreateEvent` | 创建分支/标签/仓库 | `ref`, `ref_type`（branch/tag/repository）, `description` |
| `PushEvent` | 推送了 commits | `ref`, `head`, `before`（⚠️ commits 列表 2025.10 已移除） |
| `IssuesEvent` | Issue 操作 | `action`, `issue` |
| `PullRequestEvent` | PR 操作 | `action`, `number`, `pull_request` |
| `DiscussionEvent` | 创建了 Discussion（2025.9 新增） | `discussion` |

**被排除的事件类型**（拉回来直接丢弃，不入库）：

| Event 类型 | 排除理由 |
|-----------|---------|
| `ReleaseEvent` | 与项目已有 `release_subscriptions` + `releases` 表 + `ReleasePoller`（HOM-47）语义重复，避免「following 列出现 release 事件 + release 列又出现同一条」的双显困惑 |
| 其它（Gollum/Public/Member/...） | 信噪比低，不在第一版渲染范围 |

每条事件公共字段：

```json
{
  "id":          "string（数字）",
  "type":        "WatchEvent",
  "actor":       { "login": "ruanyf", "avatar_url": "..." },
  "repo":        { "id": 123, "name": "facebook/react" },
  "payload":     { ... },
  "created_at":  "2026-06-15T12:00:00Z"
}
```

### 2.2 announcement — 双源聚合

dong4j 2026-06-16 决策 Q2：**删除 Discussions GraphQL 方案**（覆盖率 ~10-15%、字符串长度逼近 GraphQL 50KB 上限、命中率极低）。
dong4j 2026-06-16 决策 Q3：**Security Advisory 纳入第一版，但范围收窄**（避免 1810 个 repo 全打导致 rate limit 爆掉）。

| 源 | 技术 | 覆盖率 | 范围 | 说明 |
|---|------|:---:|------|------|
| GitHub Blog RSS | `github.blog/feed/` REST | 100%（非个性化） | 全量 | GitHub 平台公告主源 |
| Security Advisory | `GET /repos/{o}/{r}/security-advisories` | ~2-3% | 仅「最近 30 天有 push」的 starred repo（典型 < 200 个） | 个性化安全公告 |

**Security Advisory 范围收窄逻辑**：

```sql
SELECT id, owner, name FROM repos
WHERE is_starred = 1
  AND pushed_at >= datetime('now', '-30 days')
```

典型用户筛选下来 50~200 个 repo，单次刷新 200 req 占 4% rate limit 预算（5000 req/h），可接受。
配合 12h announcement TTL，每天约 2 次 burst，每次都按 ETag 304 短路，稳态下基本不消耗 rate limit。

**Blog RSS 字段映射**（`github.blog/feed/`）：

| RSS 字段 | 数据库映射 | 格式 |
|---------|-----------|------|
| `guid` | id（加 `blog:` 前缀，见 §3.2 P1） | `?p=96773` |
| `title` | title | CDATA |
| `link` | url | URL |
| `dc:creator` | author | 纯文本 |
| `pubDate` | created_at | RFC 2822 → ISO8601 |
| `category`（可多个） | categories JSON | `["AI & ML", "Security"]` |
| `description` | 摘要 | HTML 片段 |
| `content:encoded` | body_markdown | 完整 HTML（HTML→Markdown 转或直接走 WKWebView） |

---

## 三、数据库设计

遵循项目现有风格：ISO8601 TEXT 存日期、snake_case 列名 → GRDB camelCase CodingKeys、Bool 列用 GRDB `.boolean` 类型（对应 SQLite 0/1）。

**铁律提醒**：本项目未上线，直接改 `DatabaseMigrationsV1.swift` 的 `v1-initial`，**不写 ALTER TABLE 迁移**（参考文件头「设计原则 2」）。

### 3.1 `activity_events` — following 事件流

```sql
CREATE TABLE activity_events (
    id               TEXT PRIMARY KEY,         -- GitHub event id（数字字符串，跨 actor 全局唯一）
    event_type       TEXT NOT NULL,            -- "WatchEvent" / "ForkEvent" / ...
    actor_login      TEXT NOT NULL,
    actor_avatar_url TEXT,
    repo_name        TEXT NOT NULL,            -- "owner/repo"
    repo_id          INTEGER NOT NULL,
    payload_json     TEXT NOT NULL,            -- 完整 payload（同 releases.assets_json 模式）
    is_read          BOOLEAN NOT NULL DEFAULT 0,  -- device-local，不走 CloudKit（M2）
    created_at       TEXT NOT NULL,            -- GitHub 事件时间 ISO8601
    fetched_at       TEXT NOT NULL             -- 本地抓取时间 ISO8601
);
CREATE INDEX idx_activity_events_created ON activity_events(created_at);
CREATE INDEX idx_activity_events_type    ON activity_events(event_type);
CREATE INDEX idx_activity_events_repo    ON activity_events(repo_id);
```

GRDB 实际写法（与 `createReleases` 同款）：

```swift
try db.create(table: "activity_events") { t in
    t.column("id", .text).primaryKey()
    t.column("event_type", .text).notNull()
    t.column("actor_login", .text).notNull()
    t.column("actor_avatar_url", .text)
    t.column("repo_name", .text).notNull()
    t.column("repo_id", .integer).notNull()
    t.column("payload_json", .text).notNull()
    t.column("is_read", .boolean).notNull().defaults(to: false)
    t.column("created_at", .text).notNull()
    t.column("fetched_at", .text).notNull()
}
try db.create(index: "idx_activity_events_created", on: "activity_events", columns: ["created_at"])
try db.create(index: "idx_activity_events_type",    on: "activity_events", columns: ["event_type"])
try db.create(index: "idx_activity_events_repo",    on: "activity_events", columns: ["repo_id"])
```

### 3.2 `activity_announcements` — 公告聚合

dong4j 2026-06-16 决策 P1：**id 加 source 前缀做命名空间隔离**，与 `ActivityItem.id`（`"star:..."` / `"release-repo:..."`）风格对齐，方便 debug 看一眼来源。

```sql
CREATE TABLE activity_announcements (
    id               TEXT PRIMARY KEY,         -- "blog:96773" / "security:GHSA-..."
    source           TEXT NOT NULL,            -- "blog" / "security"
    title            TEXT NOT NULL,
    body_markdown    TEXT,                     -- 正文
    author           TEXT,
    url              TEXT NOT NULL,
    repo_name        TEXT,                     -- security 来源有，blog 无
    categories       TEXT,                     -- JSON array: ["AI & ML", "Security"]
    is_read          BOOLEAN NOT NULL DEFAULT 0,  -- device-local，不走 CloudKit（M2）
    created_at       TEXT NOT NULL,            -- 发布时间 ISO8601
    fetched_at       TEXT NOT NULL             -- 本地抓取时间 ISO8601
);
CREATE INDEX idx_activity_announcements_created ON activity_announcements(created_at);
CREATE INDEX idx_activity_announcements_source  ON activity_announcements(source);
```

### 3.3 `activity_sync_state` — 单行 meta 表（ETag + 上次清理时间）

dong4j 2026-06-16 决策 P3：events API 必须用 ETag 304 省 rate limit。
dong4j 2026-06-16 决策 P6：数据清理不能放主刷新路径，靠"距上次清理 > 24h"判定。

设计参考 `weekly_bulk_meta` 单行表风格（PK 固定值 `"singleton"`）：

```swift
try db.create(table: "activity_sync_state") { t in
    t.column("id", .text).primaryKey()                  // 固定值 "singleton"
    t.column("events_etag", .text)                      // /users/{u}/received_events ETag
    t.column("blog_rss_etag", .text)                    // github.blog/feed/ ETag
    t.column("last_events_fetched_at", .text)           // 上次成功拉 events 时间
    t.column("last_blog_fetched_at", .text)             // 上次成功拉 blog rss 时间
    t.column("last_security_fetched_at", .text)         // 上次成功拉 security advisory 时间
    t.column("last_cleanup_at", .text)                  // 上次跑 30 天清理时间，>24h 才再跑
}
```

### 3.4 数据清理策略

dong4j 2026-06-16 决策 P6：**不在主刷新路径里跑**，避免阻塞 UI loading。

**触发条件**：在 ViewModel `reload` 完成网络刷新后，异步派发 `cleanupIfNeeded()`：

```swift
private func cleanupIfNeeded() async {
    let lastCleanup = await syncStateRepo.lastCleanupAt()
    let interval = lastCleanup.map { Date().timeIntervalSince($0) } ?? .infinity
    guard interval > 86_400 else { return }  // 24h 内不重复清理

    try? await activityEventRepository.deleteOlderThan(days: 30)
    try? await activityAnnouncementRepository.deleteOlderThan(days: 30)
    await syncStateRepo.markCleanupCompleted(at: Date())
}
```

SQL：

```sql
DELETE FROM activity_events        WHERE created_at < datetime('now', '-30 days');
DELETE FROM activity_announcements WHERE created_at < datetime('now', '-30 days');
```

---

## 四、拉取策略（SWR 模式，复刻 Trending）

dong4j 2026-06-16 决策 P4：**直接复刻 `TrendingCachePolicy` enum**，不再造一遍。

### 4.1 缓存策略 enum

参考 `Starcat/Features/Trending/TrendingViewModel.swift` `TrendingCachePolicy` 完整复刻：

```swift
enum ActivityCachePolicy: Sendable {
    case respectTTL    // 进入页面 / 分类切换：TTL 内不走网络
    case forceNetwork  // 主动刷新按钮 / 错误重试：永远走网络
}
```

### 4.2 reload 行为矩阵（与 `TrendingViewModel.reload` 一一对应）

| 入口 | cachePolicy | 缓存空 | 缓存有 + TTL 内 | 缓存有 + TTL 过期 |
|------|-------------|--------|------------------|---------------------|
| 进入页面 (`.task`) | `.respectTTL` | 走网络 + `isLoading` | 上屏缓存 + **不走网络** | 上屏缓存 + 后台刷新 |
| 分类切换 | `.respectTTL` | 走网络 + `isLoading` | 上屏缓存 + 不走网络 | 上屏缓存 + 后台刷新 |
| 主动刷新按钮 | `.forceNetwork` | 走网络 + `isLoading` | 上屏缓存 + 后台刷新 | 上屏缓存 + 后台刷新 |
| 错误重试 | `.forceNetwork` | 走网络 + `isLoading` | 上屏缓存 + 后台刷新 | 上屏缓存 + 后台刷新 |

### 4.3 进度状态（同 Trending）

| 属性 | 用途 |
|------|------|
| `isLoading = true` | 无缓存时全页 ProgressView |
| `isRefreshing = true` | 有缓存时后台刷新，toolbar 图标旋转 |
| `lastRefreshedAt: Date?` | 上次成功刷新时间，驱动 `formattedFreshness` 文本 |

### 4.4 TTL 设定（dong4j 2026-06-16 决策 P5 调整后）

| 分类 | TTL | 调整理由 |
|------|-----|---------|
| following（Events） | **2h** | events API 服务端有 ~5 分钟缓存延迟，TTL 设 1h 浪费配额（用户感知不到）；2h 与「半天看一次 Activity」的产品频率对齐 |
| announcement（聚合） | **12h** | Blog RSS 每日 1-2 篇更新，12h 已远超内容更新节奏；Security Advisory 收窄到 ~200 repo 后单次刷新仍是 burst，12h 间隔保护 rate limit |
| 数据保留 | 30d | 仅保留近一个月，控制 DB 体积 |

### 4.5 4 路并行 fetch + 错误降级

ViewModel 内 4 路并行（repos / releases / events / announcements）。**任意一路失败不阻塞其它路**，参考 `TrendingViewModel.reload` 的 try/catch 内部降级：

- 有缓存 + 网络失败 → 保留缓存上屏，仅记录 `loadError` 给 toolbar 提示
- 无缓存 + 网络失败 → 走 `emptyState(errorView)` 流程

具体实现按 Trending 同款模式开工时落地，方案不展开。

---

## 五、卡片 UI 设计

### 5.1 following 事件卡片

```
┌─────────────────────────────────────────────────────────┐
│ 🔵 [类型图标]  ruanyf starred facebook/react  · 3 小时前 │
│    ────────────────────────────────────────────────────  │
│    · WatchEvent        → "Starred the repository"       │
│    · ForkEvent         → "Forked to ruanyf/my-fork"     │
│    · PushEvent         → "Pushed to main"               │
│    · CreateEvent       → "Created tag v3.0.0"           │
│    · IssuesEvent       → "Opened issue #123: title"     │
│    · PullRequestEvent  → "Merged PR #456: title"        │
│    · DiscussionEvent   → "Started discussion: title"    │
└─────────────────────────────────────────────────────────┘
```

- 标题行：`[类型图标] actor_login + action + repo_name`
- 副标题：从 `payload_json` 派生事件特有详情（字段缺失时回落到事件类型本身的文案）
- 点击 → 右侧详情面板（`activityMetadataPanel` 现有模式）

**i18n key 规划**（按军规 §5 命名 `{section}.{subsection}.{component}`，禁用 `_`）：

```
activity.following.event.watch.format
activity.following.event.fork.format
activity.following.event.push.format
activity.following.event.create.branch.format
activity.following.event.create.tag.format
activity.following.event.create.repository.format
activity.following.event.issues.opened.format
activity.following.event.issues.closed.format
activity.following.event.pullRequest.opened.format
activity.following.event.pullRequest.merged.format
activity.following.event.pullRequest.closed.format
activity.following.event.discussion.format
```

全部填 en + zh-Hans 双语。

### 5.2 announcement 卡片

```
┌─────────────────────────────────────────────────────────┐
│ 📢 GitHub Copilot CLI for Beginners             · 2 天前 │
│    ────────────────────────────────────────────────────  │
│    GitHub Blog  ·  AI & ML, GitHub Copilot               │
│    ────────────────────────────────────────────────────  │
│    正文摘要（HTML strip 后前 80 字）                     │
│    点击 → detail 面板展示完整 HTML 正文                  │
└─────────────────────────────────────────────────────────┘
```

**两个 source 视觉区分**：

| source | 主图标 | 来源 chip | 颜色 |
|--------|--------|----------|------|
| `blog` | `newspaper` | "GitHub Blog" | category iconColor |
| `security` | `shield.lefthalf.filled` | "Security Advisory" | 红色 / orange tint |

### 5.3 右侧详情面板

遵循 `ActivityDetailView.activityMetadataPanel` 现有模式：

- **following event 详情**：actor 头像 + 事件类型解释 + payload 展开
- **announcement 详情**：标题 + 来源标签 + 发布时间 + 正文渲染（HTML 走 WKWebView，复用 `ReadmeWebView` 同款）

---

## 六、实现清单

dong4j 2026-06-16 决策 M3：**切 3 个 PR**，每个 PR 可独立 review + 合并。

### PR-1：数据库 + Repository + i18n 骨架（不接网络）

| 步骤 | 内容 | 涉及文件 |
|:---:|------|---------|
| 1 | 新增 3 张表 `activity_events` / `activity_announcements` / `activity_sync_state`（合并进 `v1-initial`） | `DatabaseMigrationsV1.swift` |
| 2 | 新增 GRDB Record struct | `ActivityEventRecord.swift` / `ActivityAnnouncementRecord.swift` |
| 3 | 新增 Repository 层 protocol + 实现（fetch / upsert / deleteOlderThan / freshness 查询） | `ActivityEventRepositoryProtocol.swift` / `ActivityEventRepository.swift` / `ActivityAnnouncementRepositoryProtocol.swift` / `ActivityAnnouncementRepository.swift` / `ActivitySyncStateRepository.swift` |
| 4 | 补充 i18n 字符串（en + zh-Hans 双语，覆盖 §5.1 全部 key） | `Localizable.xcstrings` |
| 5 | 单测：Repository CRUD + 30 天清理边界 | `ActivityEventRepositoryTests.swift` / `ActivityAnnouncementRepositoryTests.swift` |

**验收**：`xcodebuild test` 全绿，UI 无可见变化。

### PR-2：following GitHub Events 接入 + SWR 改造

| 步骤 | 内容 | 涉及文件 |
|:---:|------|---------|
| 6 | 新增网络层 Events REST 接入（注意 ETag 304） | `GitHubEventsAPI.swift`（放 `Starcat/Core/Network/GitHubAPI/`） |
| 7 | `ActivityViewModel` 改造：引入 `ActivityCachePolicy` enum、4 路并行 fetch、错误降级（复刻 `TrendingViewModel.reload` 模式）、新增 `makeFollowingItems` | `ActivityViewModel.swift` |
| 8 | following 卡片行 UI（payload 解析 + 类型图标） | `ActivityFollowingRowView.swift` 或合并进 `ActivityRowView` |
| 9 | 详情面板支持 following event 类型展开 | `ActivityDetailView.swift` |
| 10 | `cleanupIfNeeded()` 后台调度（>24h 触发） | `ActivityViewModel.swift` |
| 11 | 单测：4 路并行 fetch 错误降级矩阵 + payload 解析 | `ActivityViewModelTests.swift` |

**验收**：following 分类不再永远空列表，TTL/ETag 行为可观察。

### PR-3：announcement Blog RSS + Security Advisory

| 步骤 | 内容 | 涉及文件 |
|:---:|------|---------|
| 12 | RSS Parser（HTML → 摘要，参考 `WeeklyAPI` / `ReadmeHTMLAPI` 复用 URLSession） | `GitHubBlogRSSAPI.swift` |
| 13 | Security Advisory API（per-repo，范围收窄逻辑） | `GitHubSecurityAdvisoryAPI.swift` |
| 14 | `makeAnnouncementItems` 改造：从硬编码改为读 `activity_announcements` 表 | `ActivityViewModel.swift` |
| 15 | announcement 卡片行 UI（blog / security 两源视觉分化） | `ActivityAnnouncementRowView.swift` |
| 16 | 详情面板 HTML 渲染（WKWebView 复用 `ReadmeWebView`） | `ActivityDetailView.swift` |
| 17 | 单测：RSS 解析 + Security Advisory 范围收窄 SQL | `GitHubBlogRSSAPITests.swift` 等 |

**验收**：announcement 分类显示真实 GitHub Blog 公告 + 用户活跃 starred repo 的安全公告。

### 三个 PR 通用

每个 PR 完成后必须：

1. 在 `docs/功能实现总览.md` 追加 `- [x] PR-N` 条目 + `> 实现：...` 行（AGENTS.md 铁律）
2. 跑 `xcodegen generate` 同步 project（新增 swift 文件后必须）
3. 跑 `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test`

---

## 七、已知约束与风险

1. **PushEvent commits 字段已移除**（GitHub 2025.10），无法展示推送了哪些 commit，只能显示 "Pushed to main"
2. **`received_events` 数据量波动大**：如果用户关注了大量活跃用户（如 `torvalds`、`ruanyf`），30 天 300 条可能不够；但如果用户没关注任何人，feed 永远是空 → UI 需要给空 feed 引导文案（"去 GitHub 关注一些感兴趣的开发者吧"）
3. **GitHub Events API 有 ~5 分钟服务端缓存延迟**（GitHub 官方文档明示），UI 不要承诺「实时」语义
4. **RSS `content:encoded` 为完整 HTML**：卡片摘要需 strip HTML tags；详情页用 WKWebView 渲染（复用 `ReadmeWebView`）
5. **Security Advisory rate limit 防护**：即使收窄到 ~200 repo，单次刷新仍是 burst。12h TTL + ETag 304 双保护；如未来用户 starred repo 推高到 500+ active，需要再降阈值或改异步分批
6. **CloudKit 不同步**（dong4j 2026-06-16 决策 M2）：`activity_events` / `activity_announcements` 是 ephemeral feed，`is_read` 等字段不挂 CloudKit。理由：跨设备同步「上次看到哪条 feed」价值低、每设备独立看 feed 体验更自然；30 天数据 × 多设备会推高 zone 体积也是负担
7. **第一版排除的事件**：ReleaseEvent（与 releases 表语义重复，决策 Q1）/ Gollum/Public/Member 等（信噪比低）
8. **第一版排除的 announcement 源**：Discussions GraphQL（决策 Q2，覆盖率 < 5% 而 query 字符串接近 GraphQL 上限）

---

## 八、与既有架构的衔接点

| 既有组件 | 衔接点 |
|---------|--------|
| `DatabaseMigrationsV1.v1-initial` | 3 张新表合并进同一 migration（铁律：上线前不写 ALTER） |
| `TrendingViewModel.TrendingCachePolicy` | `ActivityCachePolicy` 直接复刻 |
| `TrendingViewModel.reload(cachePolicy:)` | `ActivityViewModel.reload` 4 路并行 + 错误降级照搬 |
| `SyncIconButton` + `formattedFreshness` | toolbar 刷新按钮 + 「上次刷新于 X 分钟前」复用 |
| `release_subscriptions` + `releases`（HOM-47） | following 主动排除 ReleaseEvent 不重复入库 |
| `weekly_bulk_meta` 单行 meta 表设计 | `activity_sync_state` 同款风格（PK 固定 `"singleton"`） |
| `ReadmeWebView` | announcement 详情 HTML 渲染复用 |
| `Localizable.xcstrings` | i18n key 命名 `activity.following.*` / `activity.announcement.*` |
| `LocaleStore` + `\.locale` 注入 | 时间格式化遵守 i18n 军规 §4 |
| `release_subscriptions` ETag 模式 | `activity_sync_state.events_etag` 同款 304 短路 |
