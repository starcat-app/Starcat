# Trending 数据本地缓存设计方案

## 1. 背景与问题

### 当前状态
- **TrendingRepository**：纯内存缓存，应用重启后丢失
- **TTL 策略**：daily=1h, weekly=6h, monthly=12h
- **README**：使用 `ReadmeRepository` 关联 `repoId (Int64)` 存储

### 问题
1. 每次打开应用，Trending 列表需要重新拉取
2. 每次点击 Trending repo，README 需要重新拉取
3. 用户 starred 的 Trending repo 数据与应用重启后丢失

### 需求
- Trending 列表数据持久化到 SQLite
- 复用已有 `Repo` 表还是新建专用表？
- README 缓存如何与 Trending repo 关联？

---

## 2. 方案对比

### 方案 A：复用 `repos` 表

**思路**：Trending repo 直接 upsert 到已有 `repos` 表

**优点**：
- 无需新建表， schema 变更最小
- Trending repo 与用户 starred repo 统一管理
- 现有 `Repo` 模型可直接复用

**缺点**：
- `repos` 表以 `id (Int64)` 为主键，Trending repo 使用 `fullName` 标识，需额外处理
- 无法区分"用户主动 star" vs "从 Trending 缓存的"
- `is_starred` 字段语义会混淆

**关键字段映射**：
| TrendingRepo | Repo |
|-------------|------|
| `fullName` | `fullName` (unique) |
| `starsCount` | `starsCount` |
| `forksCount` | `forksCount` |
| `language` | `language` |
| `description` | `description` |
| `url.absoluteString` | `htmlUrl` |

### 方案 B：新建 `trending_repos` 表

**思路**：新建专用表存储 Trending 数据

**优点**：
- 数据隔离，语义清晰
- 可独立管理生命周期（如定时清理过期数据）
- 不影响现有 `repos` 表逻辑

**缺点**：
- 需要新增 schema migration
- 需处理与 `repos` 表的数据同步（如用户 star 了某个 Trending repo）

### 方案 C：仅缓存列表，元数据按需加载

**思路**：
- `trending_repos` 表存储列表（fullName、stars、forks 等基础字段）
- README 缓存改用 `fullName` 关联（需扩展 `readmes` 表）

**优点**：
- 列表缓存开销小
- README 缓存独立，可复用已有模式

**缺点**：
- 需修改 `readmes` 表结构或新建 `trending_readmes` 表
- 改动面较大

---

## 3. 推荐方案：方案 A（复用 `repos` 表）

### 理由
1. **改动最小**：无需新增表和 migration
2. **数据复用**：用户 star 的 Trending repo 可直接转为本地 star
3. **模型统一**：`Repo` 模型已完整，只需扩展 Trending 特有字段

### 详细设计

#### 3.1 新增字段

在 `repos` 表新增 Trending 特有字段：

```sql
ALTER TABLE repos ADD COLUMN trending_period TEXT;      -- 'daily'/'weekly'/'monthly'
ALTER TABLE repos ADD COLUMN trending_stars_delta INTEGER DEFAULT 0;  -- 周期内新增 stars
ALTER TABLE repos ADD COLUMN trending_contributors TEXT; -- JSON 数组，贡献者列表
ALTER TABLE repos ADD COLUMN trending_cached_at TEXT;  -- Trending 缓存时间
```

#### 3.2 TrendingRepo 与 Repo 的映射

```swift
extension Repo {
    /// 从 TrendingRepo 转换
    static func from(trending: TrendingRepo, period: TrendingPeriod) -> Repo {
        Repo(
            id: 0,  // Trending repo 无真实 ID，设为 0 占位
            owner: trending.owner,
            name: trending.name,
            fullName: trending.fullName,
            description: trending.description,
            language: trending.language,
            starsCount: trending.starsCount,
            forksCount: trending.forksCount,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: trending.url.absoluteString,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: false,  // 默认未 star
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: ISO8601DateFormatter.shared.string(from: Date())
        )
    }
}
```

#### 3.3 TrendingRepository 改造

**新增依赖**：
```swift
actor TrendingRepository {
    private let api: TrendingAPI
    private let database: any DatabaseManaging  // 新增
    private var cache: [CacheKey: CacheEntry] = [:]
}
```

**持久化逻辑**：
```swift
func fetchTrending(since: TrendingPeriod, language: TrendingLanguage) async throws -> [TrendingRepo] {
    let key = CacheKey(period: since, language: language)

    // 1. 先查本地数据库
    let cached = try await loadFromDatabase(since: since, language: language)
    if let cached = cached, !cached.isExpired(ttl: Self.ttl(for: since)) {
        return cached.repos
    }

    // 2. 本地无或已过期，查网络
    let repos = try await api.fetchTrending(since: since, language: language)

    // 3. 写入本地数据库
    try await saveToDatabase(repos: repos, period: since, language: language)

    return repos
}

private func loadFromDatabase(since: TrendingPeriod, language: TrendingLanguage) async throws -> CacheEntry? {
    // SELECT * FROM repos WHERE trending_period = ? AND trending_cached_at > ?
}

private func saveToDatabase(repos: [TrendingRepo], period: TrendingPeriod, language: TrendingLanguage) async throws {
    // UPSERT 每个 repo 到数据库
}
```

#### 3.4 README 缓存关联

**问题**：`readmes` 表使用 `repoId (Int64)` 关联，Trending repo 无真实 ID

**解决**：扩展 `readmes` 表支持 `fullName` 关联

```sql
ALTER TABLE readmes ADD COLUMN full_name TEXT;  -- 可空，Trending repo 使用

-- 复合唯一索引
CREATE UNIQUE INDEX idx_readmes_fullname ON readmes(full_name) WHERE full_name IS NOT NULL;
```

**Readme 模型扩展**：
```swift
struct Readme: Codable, FetchableRecord, MutablePersistableRecord {
    var repoId: Int64?        // 可空
    var fullName: String?      // 可空，Trending repo 使用
    // ... 其他字段
}
```

---

## 4. 主动刷新按钮

### 4.1 UI 设计

在"今日/本周/本月"筛选项的**右对齐**位置添加刷新按钮：

```
┌─────────────────────────────────────────────────────────────┐
│  [ 今日 ] [ 本周 ] [ 本月 ]                    🔄 刷新   │
└─────────────────────────────────────────────────────────────┘
```

**视觉规范**：
- 图标：`arrow.clockwise`
- 风格：`buttonStyle(.plain)` + `.focusEffectDisabled()`
- 提示文本：tooltip 显示"刷新 Trending 数据"
- 加载状态：显示 spinner 并禁用点击

### 4.2 交互逻辑

```swift
// TrendingView.swift
private var toolbarView: some View {
    HStack {
        periodPicker

        Spacer()

        refreshButton
    }
}

private var refreshButton: some View {
    Button {
        Task {
            isRefreshing = true
            await viewModel.forceRefresh()
            isRefreshing = false
        }
    } label: {
        if isRefreshing {
            ProgressView()
                .scaleEffect(0.6)
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .disabled(isRefreshing)
    .help("刷新 Trending 数据")
}
```

### 4.3 ViewModel 方法

```swift
// TrendingViewModel.swift

/// 主动刷新（绕过缓存，直接请求 API 并更新本地数据库）
func forceRefresh() async {
    // 1. 调用 API 获取最新数据
    let repos = try? await repository.fetchTrending(since: selectedPeriod, language: selectedLanguage)

    // 2. 强制写入本地数据库（覆盖）
    if let repos = repos {
        try? await saveToDatabase(repos: repos, period: selectedPeriod, language: selectedLanguage)
    }
}
```

---

## 5. 改动范围

### 5.1 新增 Migration

```swift
// DatabaseMigrations.swift 新增 v5
static let migrationToV5 = Migration(
    version: 5,
    description: "Add Trending cache fields to repos table and full_name to readmes"
) { db in
    // repos 表新增字段
    try db.alter(table: "repos") { t in
        t.add(column: "trending_period", .text)
        t.add(column: "trending_stars_delta", .integer).defaults(to: 0)
        t.add(column: "trending_contributors", .text)
        t.add(column: "trending_cached_at", .text)
    }

    // readmes 表新增字段
    try db.alter(table: "readmes") { t in
        t.add(column: "full_name", .text)
    }

    try db.create(
        index: "idx_readmes_fullname",
        on: "readmes",
        columns: ["full_name"],
        condition: Column("full_name") != nil,
        unique: true
    )
}
```

### 5.2 修改的文件

| 文件 | 改动 |
|------|------|
| `Repo.swift` | 新增 `from(trending:)` 工厂方法 |
| `TrendingRepository.swift` | 注入 DatabaseManaging，实现持久化读写 |
| `ReadmeRepository.swift` | 支持 `fullName` 查询 |
| `ReadmeAPI.swift` | 已有 `refreshTrendingReadme`，无需改动 |
| `ReadmeViewModel.swift` | 已有 `loadTrending`，无需改动 |
| `DatabaseMigrations.swift` | 新增 v5 migration |

### 5.3 新增文件

- `TrendingRepoRepository.swift`（可选）：如果不想污染 `TrendingRepository`，可新建专门的缓存仓库

---

## 6. 生命周期管理

### 5.1 TTL 策略

| 周期 | TTL | 说明 |
|------|-----|------|
| daily | 1 小时 | 变化频繁 |
| weekly | 6 小时 | 中等变化 |
| monthly | 12 小时 | 变化较慢 |

### 5.2 清理策略

- **启动时清理**：删除超过 24 小时的 daily 缓存、超过 7 天的 weekly 缓存、超过 30 天的 monthly 缓存
- **手动刷新**：用户在 Trending 页面下拉刷新时，强制更新

### 5.3 数据过期处理

```swift
// CacheCleaner 扩展
func cleanTrendingCache() async {
    let cutoff = Date().addingTimeInterval(-24 * 3600)
    try await database.write { db in
        try db.execute(sql: """
            DELETE FROM repos
            WHERE trending_period = 'daily'
            AND trending_cached_at < ?
        """, arguments: [cutoff])
    }
}
```

---

## 7. 风险与注意事项

### 6.1 `id = 0` 占位问题
- Trending repo 的 `id = 0` 是占位值，不应与真实 repo 冲突
- 数据库查询时应优先使用 `fullName` 而非 `id`

### 6.2 数据一致性
- 用户 star 了 Trending repo 后，应将数据从 `trending_repos` 合并到正常 `repos` 表
- 合并后删除 Trending 缓存记录

### 6.3 并发安全
- `TrendingRepository` 是 `actor`，本身线程安全
- 数据库写入需要通过 `DatabaseWriter` 的队列

---

## 8. 实现步骤

1. **Phase 1：数据库扩展**
   - 新增 migration v5
   - 扩展 `Repo` 模型
   - 扩展 `Readme` 模型

2. **Phase 2：TrendingRepository 持久化**
   - 注入 `DatabaseManaging`
   - 实现 `loadFromDatabase` / `saveToDatabase`
   - 修改 `fetchTrending` 逻辑

3. **Phase 3：清理与统计**
   - 扩展 `CacheCleaner`
   - 添加清理定时任务

4. **Phase 4（可选）：数据合并**
   - 用户 star Trending repo 时合并到正常 repos 表
   - 避免数据孤岛
