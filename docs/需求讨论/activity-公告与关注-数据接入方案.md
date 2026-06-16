# Activity 公告与关注 — 数据接入方案

> 状态：方案讨论完成，待确认开工
> 日期：2026-06-16

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

**事件类型与可用字段**：

| Event 类型 | 含义 | 关键 payload 字段 |
|-----------|------|------------------|
| `WatchEvent` | 某人 star 了仓库 | `action: "started"` |
| `ForkEvent` | 某人 fork 了仓库 | `forkee`（含完整 fork 仓库信息） |
| `ReleaseEvent` | 仓库发布了新版本 | `release` → tag_name, name, body, html_url, author |
| `CreateEvent` | 创建分支/标签/仓库 | `ref`, `ref_type`（branch/tag/repository）, `description` |
| `PushEvent` | 推送了 commits | `ref`, `head`, `before`（⚠️ commits 列表 2025.10 已移除） |
| `IssuesEvent` | Issue 操作 | `action`, `issue` |
| `PullRequestEvent` | PR 操作 | `action`, `number`, `pull_request` |
| `DiscussionEvent` | 创建了 Discussion（2025.9 新增） | `discussion` |

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

### 2.2 announcement — 三源聚合

| 源 | 技术 | 覆盖率 | 说明 |
|---|------|:---:|------|
| GitHub Discussions | GraphQL `search(type: DISCUSSION)` | ~10-15% | starred repos 中 Announcements 类别 |
| GitHub Blog RSS | `github.blog/feed/` REST | 100%（非个性化） | GitHub 平台公告兜底 |
| Security Advisory | `GET /repos/{o}/{r}/security-advisories` | ~2-3% | 少量仓库的 GHSA |

**GraphQL Search 跨仓库查询**（避免 N+1）：

```graphql
query {
  search(
    query: "repo:owner/repo1 repo:owner/repo2 is:discussion category:Announcements"
    type: DISCUSSION
    first: 50
  ) {
    discussionCount
    nodes {
      ... on Discussion {
        id number title body url createdAt
        repository { nameWithOwner }
        category { name }
        author { login }
      }
    }
  }
}
```

**RSS 字段**（`github.blog/feed/`）：

| RSS 字段 | 数据库映射 | 格式 |
|---------|-----------|------|
| `guid` | 去重主键 | `?p=96773` |
| `title` | title | CDATA |
| `link` | url | URL |
| `dc:creator` | author | 纯文本 |
| `pubDate` | created_at | RFC 2822 → ISO8601 |
| `category`（可多个） | categories JSON | `["AI & ML", "Security"]` |
| `description` | 摘要 | HTML 片段 |
| `content:encoded` | 正文 | 完整 HTML |

---

## 三、数据库设计

遵循项目现有风格：ISO8601 TEXT 存日期、snake_case 列名 → GRDB camelCase CodingKeys。

### 3.1 `activity_events` — following 事件流

```sql
CREATE TABLE activity_events (
    id               TEXT PRIMARY KEY,         -- GitHub event id
    event_type       TEXT NOT NULL,            -- "WatchEvent" / "ReleaseEvent" ...
    actor_login      TEXT NOT NULL,
    actor_avatar_url TEXT,
    repo_name        TEXT NOT NULL,            -- "owner/repo"
    repo_id          INTEGER NOT NULL,
    payload_json     TEXT NOT NULL,            -- 完整 payload（同 releases.assets_json 模式）
    is_read          BOOLEAN NOT NULL DEFAULT false,
    created_at       TEXT NOT NULL,            -- GitHub 事件时间 ISO8601
    fetched_at       TEXT NOT NULL             -- 本地抓取时间 ISO8601
);
CREATE INDEX idx_activity_events_created ON activity_events(created_at);
CREATE INDEX idx_activity_events_type    ON activity_events(event_type);
CREATE INDEX idx_activity_events_repo    ON activity_events(repo_id);
```

### 3.2 `activity_announcements` — 公告聚合

```sql
CREATE TABLE activity_announcements (
    id               TEXT PRIMARY KEY,         -- RSS guid / Discussion node_id / GHSA id
    source           TEXT NOT NULL,            -- "blog" / "discussion" / "security"
    title            TEXT NOT NULL,
    body_markdown    TEXT,                     -- 正文
    author           TEXT,
    url              TEXT NOT NULL,
    repo_name        TEXT,                     -- 关联仓库（discussion/security 有，blog 无）
    categories       TEXT,                     -- JSON array: ["AI & ML", "Security"]
    is_read          BOOLEAN NOT NULL DEFAULT false,
    created_at       TEXT NOT NULL,            -- 发布时间 ISO8601
    fetched_at       TEXT NOT NULL             -- 本地抓取时间 ISO8601
);
CREATE INDEX idx_activity_announcements_created ON activity_announcements(created_at);
CREATE INDEX idx_activity_announcements_source  ON activity_announcements(source);
```

### 3.3 数据清理策略

每次刷新时执行，仅保留近 30 天：

```sql
DELETE FROM activity_events        WHERE created_at < datetime('now', '-30 days');
DELETE FROM activity_announcements WHERE created_at < datetime('now', '-30 days');
```

---

## 四、拉取策略（SWR 模式，对标 Trending）

```
┌─ 进入 Activity 页 ──────────────────────────────────────────
│  1. 立即读 DB 缓存（快）
│  2. 检查上次刷新时间
│     ├─ < 1h → 仅展示缓存（respectTTL，TTL = 3600s）
│     └─ >= 1h → 后台静默刷新（SWR: 缓存先显示，再更新）
│
├─ 用户点刷新按钮 / 下拉 → forceNetwork
│
├─ 后台定时器 → 每 1h 自动 respectTTL（app 前台时）
│
└─ 列表顶部显示 "上次刷新于 X 分钟前"
   （复用 SyncIconButton + formattedFreshness，与 Trending 同款）
```

### 4.1 进度状态

| 属性 | 用途 |
|------|------|
| `isLoading = true` | 无缓存时全页 ProgressView |
| `isRefreshing = true` | 有缓存时后台刷新，toolbar 图标旋转 |
| `lastRefreshedAt: Date?` | 上次成功刷新时间，驱动 freshness 文本 |

### 4.2 TTL 设定

| 分类 | TTL | 理由 |
|------|-----|------|
| following（Events） | 1h | 事件流更新频率较高 |
| announcement（聚合） | 6h | RSS 每日更新 1-2 篇，Discussions 低频 |
| 数据保留 | 30d | 仅保留近一个月，控制 DB 体积 |

---

## 五、卡片 UI 设计

### 5.1 following 事件卡片

```
┌─────────────────────────────────────────────────────────┐
│ 🔵 [类型图标]  ruanyf starred facebook/react  · 3 小时前 │
│    ────────────────────────────────────────────────────  │
│    · WatchEvent    → "Starred the repository"           │
│    · ReleaseEvent  → "v2.5.0 — Bug fixes and ..."      │
│    · ForkEvent     → "Forked to ruanyf/my-fork"        │
│    · PushEvent     → "Pushed to main"                  │
│    · CreateEvent   → "Created tag v3.0.0"              │
│    · IssuesEvent   → "Opened issue #123: title"        │
│    · PullRequestEvent → "Merged PR #456: title"        │
│    · DiscussionEvent  → "Started discussion: title"    │
└─────────────────────────────────────────────────────────┘
```

- 标题行：`[类型图标] actor_login + action + repo_name`
- 副标题：从 payload_json 派生事件特有详情
- 点击 → 右侧详情面板（activityMetadataPanel 现有模式）

### 5.2 announcement 卡片

```
┌─────────────────────────────────────────────────────────┐
│ 📢 GitHub Copilot CLI for Beginners             · 2 天前 │
│    ────────────────────────────────────────────────────  │
│    GitHub Blog  ·  AI & ML, GitHub Copilot               │
│    ────────────────────────────────────────────────────  │
│    正文摘要（markdown strip 后前 80 字）                 │
│    点击 → detail 面板展示完整 markdown/HTML 正文         │
└─────────────────────────────────────────────────────────┘
```

### 5.3 右侧详情面板

遵循 `ActivityDetailView.activityMetadataPanel` 现有模式：

- **following event 详情**：actor 头像 + 事件类型解释 + payload 展开（如 Release 显示 tag_name + body + assets）
- **announcement 详情**：标题 + 来源标签 + 发布时间 + 正文渲染（markdown / HTML）

---

## 六、实现清单

| 步骤 | 内容 | 涉及文件 |
|:---:|------|---------|
| 1 | 新增 `activity_events` / `activity_announcements` 表 | `DatabaseMigrationsV1.swift` |
| 2 | 新增 GRDB Record struct | `ActivityEventRecord.swift` / `ActivityAnnouncementRecord.swift` |
| 3 | 新增 Repository 层（fetch / upsert / cleanup / freshness 查询） | `ActivityEventRepository.swift` / `ActivityAnnouncementRepository.swift` |
| 4 | 新增网络层（Events REST + Discussions GraphQL + RSS Parser） | `GitHubEventsService.swift` / `GitHubAnnouncementsService.swift` |
| 5 | 改造 `ActivityViewModel`：新增 `makeFollowingItems` + 改造 `makeAnnouncement`，接入仓库数据 | `ActivityViewModel.swift` |
| 6 | 新增事件卡片行 UI | `ActivityEventRowView.swift` / `ActivityAnnouncementRowView.swift` |
| 7 | 新增刷新控件（复用 `SyncIconButton` + `formattedFreshness`，对标 Trending 布局） | `ActivityView.swift` |
| 8 | 补充 i18n 字符串（en + zh-Hans 双语） | `Localizable.xcstrings` |
| 9 | 更新进度文档 | `功能实现总览.md` |

---

## 七、已知约束与风险

1. **PushEvent commits 字段已移除**（GitHub 2025.10），无法展示推送了哪些 commit，只能显示 "Pushed to main"
2. **Discussions 覆盖率低**：大部分 GitHub 仓库未启用 Discussions，announcement 列表将以 Blog RSS 为主
3. **`received_events` 数据量波动大**：如果用户关注了大量活跃用户（如 `torvalds`、`ruanyf`），30 天 300 条可能不够
4. **RSS `content:encoded` 为完整 HTML**：卡片摘要需 strip HTML tags；详情页建议用 WKWebView 渲染
5. **GraphQL Search 查询字串长度限制**：如果用户 starred 仓库数很多（如 1000+），不能全部拼进 `repo:` 限定符，需要分批或优先选最近 starred 的
