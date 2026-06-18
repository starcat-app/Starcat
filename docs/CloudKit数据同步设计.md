# CloudKit 数据同步设计

> 本文档定义 CloudKit 的 Schema 设计，用于多端用户数据同步。
>
> **设计思路**：用户数据优先，云端为本。仅同步用户生成数据，不同步可重建的缓存数据。
>
> **产品决策（2026-06-18）**：CloudKit **v1 不实施**；上线后为 **Pro 订阅权益**。见 `docs/StoreKit订阅上架方案.md` §2、§3。

---

## 一、设计原则

### 1.1 数据分类

| 数据类型 | 是否同步 | 说明 |
|---------|---------|------|
| Tags | ✅ 同步 | 用户创建的标签 |
| RepoNotes | ✅ 同步 | 用户写的笔记 |
| RepoStatus | ✅ 同步 | 阅读状态 |
| SavedSearches | ✅ 同步 | 保存的搜索 |
| SearchHistory | ✅ 同步 | 搜索关键词历史（useCount 走 max 合并，见 §2.6.1） |
| ReleaseSubscriptions | ✅ 同步 | Release 订阅设置 |
| User Preferences | ✅ 同步 | 用户设置 |
| Repo 缓存 | ❌ 不同步 | 可从 GitHub 重建 |
| README 缓存 | ❌ 不同步 | 可按需拉取 |
| AI Summaries | ❌ 不同步 | 可重新生成 |
| Embeddings | ❌ 不同步 | 可重新计算 |

### 1.2 同步策略

```
┌─────────────────────────────────────────────────────────────┐
│                    冲突解决策略                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Last-Write-Wins (基于 modifiedAt 时间戳)                  │
│                                                              │
│  场景：用户同时在 Mac 和 iPhone 编辑同一笔记               │
│                                                              │
│  Mac 修改：modifiedAt = 2026-05-29T10:00:00Z              │
│  iPhone 修改：modifiedAt = 2026-05-29T10:01:00Z           │
│                                                              │
│  结果：iPhone 的版本优先                                    │
│                                                              │
│  注意：删除操作保留 tombstone，用于跨设备同步删除            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、CloudKit Schema

### 2.1 Record Types

```
┌─────────────────────────────────────────────────────────────┐
│                    CloudKit Record Types                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  CKRecordType_Tag                → 标签                    │
│  CKRecordType_RepoTag            → 仓库-标签关联            │
│  CKRecordType_RepoNote           → 仓库笔记                │
│  CKRecordType_RepoStatus         → 仓库状态                │
│  CKRecordType_SavedSearch        → 保存的搜索               │
│  CKRecordType_SearchHistory      → 搜索历史（含使用次数）   │
│  CKRecordType_ReleaseSubscription → Release 订阅             │
│  CKRecordType_UserPreferences     → 用户设置                │
│  CKRecordType_Tombstone          → 删除标记                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Tag (标签)

```swift
// CKRecordType: "Tag"
let tagRecord = CKRecord(recordType: "Tag")
tagRecord["id"] = "uuid-string"           // UUID
tagRecord["name"] = "AI"                  // 标签名
tagRecord["color"] = "#FF5722"           // 颜色
tagRecord["icon"] = "sparkles"           // SF Symbol
tagRecord["sortOrder"] = 0               // Int
tagRecord["isPreset"] = false           // Bool
tagRecord["parentID"] = "parent-uuid"   // 可选，嵌套标签
tagRecord["createdAt"] = Date()
tagRecord["modifiedAt"] = Date()
```

### 2.3 RepoTag (仓库-标签关联)

```swift
// CKRecordType: "RepoTag"
let repoTagRecord = CKRecord(recordType: "RepoTag")
repoTagRecord["id"] = "uuid-string"           // UUID
repoTagRecord["repoID"] = "github-12345"    // GitHub Repo ID
repoTagRecord["tagID"] = "tag-uuid"          // 关联的 Tag ID
repoTagRecord["createdAt"] = Date()
```

### 2.4 RepoNote (仓库笔记)

```swift
// CKRecordType: "RepoNote"
let noteRecord = CKRecord(recordType: "RepoNote")
noteRecord["id"] = "uuid-string"
noteRecord["repoID"] = "github-12345"       // GitHub Repo ID
noteRecord["content"] = "# 笔记\n这是我的笔记..." // Markdown
noteRecord["isAIGenerated"] = false          // 是否 AI 生成
noteRecord["editedAt"] = Date()
noteRecord["createdAt"] = Date()
noteRecord["modifiedAt"] = Date()
```

### 2.5 RepoStatus (仓库状态)

```swift
// CKRecordType: "RepoStatus"
let statusRecord = CKRecord(recordType: "RepoStatus")
statusRecord["id"] = "uuid-string"
statusRecord["repoID"] = "github-12345"
statusRecord["status"] = "reading"  // "unread" | "reading" | "using" | "deprecated"
statusRecord["modifiedAt"] = Date()
```

### 2.6 SavedSearch (保存的搜索)

```swift
// CKRecordType: "SavedSearch"
let searchRecord = CKRecord(recordType: "SavedSearch")
searchRecord["id"] = "uuid-string"
searchRecord["name"] = "Python AI Projects"
searchRecord["queryJSON"] = """
{
    "keyword": "Python AI",
    "language": "Python",
    "tags": ["AI", "ML"],
    "sortBy": "stars"
}
"""
searchRecord["createdAt"] = Date()
searchRecord["modifiedAt"] = Date()
searchRecord["lastUsedAt"] = Date()
```

### 2.6.1 SearchHistory (搜索历史)

> **新增于 2026-06-14**：从 UserDefaults 升级到 SQLite + CloudKit-ready 字段。
> 本期（W4）仅本地持久化；CloudKit 实际同步在 W5 跟 Tag / RepoNote / SavedSearch 一起接入。

```swift
// CKRecordType: "SearchHistory"
let historyRecord = CKRecord(recordType: "SearchHistory")
historyRecord["id"] = "uuid-string"            // UUID
historyRecord["query"] = "swift concurrency"   // 原始输入（保留大小写）
historyRecord["queryLower"] = "swift concurrency" // 小写归一，去重键
historyRecord["useCount"] = 5                  // Int，累计使用次数
historyRecord["lastUsedAt"] = Date()           // 排序衰减 + UI 显示
historyRecord["firstSeenAt"] = Date()          // 首次记录
historyRecord["modifiedAt"] = Date()           // CloudKit LWW 时间戳
```

**特殊冲突合并策略**（不同于其它 user-data 的纯 LWW）：

- `modifiedAt` 较新者整体取优；
- **但 `useCount = max(local, remote)`** —— 避免 "Mac 搜了 5 次、iPhone 搜了 3 次，
  同步后只剩 3 次" 的明显计数倒退。
- 这是本表与 Tag/RepoNote 纯 LWW 的**唯一差异**，实现时在 `CloudKitSync.applyRemoteRecord`
  里专项处理（W5 落地）。

**字段使用建议**：
- `queryLower` 作 UNIQUE 索引，CloudKit 端用 `CKQueryOperation` 按 `lower` 去重；
- `useCount` 不进 CloudKit Queryable Index（不参与 server-side 排序，由客户端
  内存里按 `decayedScore` 计算排序）；
- 历史总数客户端硬上限 50，超出后按 `decayedScore` 升序淘汰最低分项，淘汰时
  写 Tombstone 同步给其它设备。

### 2.7 ReleaseSubscription (Release 订阅)

```swift
// CKRecordType: "ReleaseSubscription"
let subRecord = CKRecord(recordType: "ReleaseSubscription")
subRecord["id"] = "uuid-string"
subRecord["repoID"] = "github-12345"
subRecord["isSubscribed"] = true
subRecord["notifyEnabled"] = true
subRecord["lastKnownVersion"] = "v1.2.0"
subRecord["modifiedAt"] = Date()
```

### 2.8 UserPreferences (用户设置)

```swift
// CKRecordType: "UserPreferences"
let prefsRecord = CKRecord(recordType: "UserPreferences")
prefsRecord["id"] = "uuid-string"
prefsRecord["syncFrequency"] = "auto"      // "auto" | "manual"
prefsRecord["defaultSortOrder"] = "starredAt"  // "starredAt" | "stars" | "name"
prefsRecord["listDensity"] = "comfortable"    // "compact" | "comfortable"
prefsRecord["aiProvider"] = "gemini"       // "gemini" | "openai" | "custom"
prefsRecord["modifiedAt"] = Date()
```

### 2.9 Tombstone (删除标记)

```swift
// CKRecordType: "Tombstone"
// 用于跨设备同步删除操作
let tombstone = CKRecord(recordType: "Tombstone")
tombstone["id"] = "uuid-string"
tombstone["originalRecordType"] = "Tag"  // 被删除的记录类型
tombstone["originalRecordID"] = "tag-uuid" // 被删除的记录 ID
tombstone["deletedAt"] = Date()

// Tombstone 保留 30 天后自动清理
```

---

## 三、CloudKit 索引设计

### 3.1 Queryable Indexes

为了支持高效查询，需要为以下字段创建索引：

| Record Type | Queryable Fields |
|-------------|------------------|
| Tag | `name`, `modifiedAt` |
| RepoTag | `repoID`, `tagID` |
| RepoNote | `repoID`, `modifiedAt` |
| RepoStatus | `repoID`, `status` |
| SavedSearch | `name`, `lastUsedAt` |
| ReleaseSubscription | `repoID`, `isSubscribed` |
| UserPreferences | `modifiedAt` |

### 3.2 Zone Configuration

```swift
// 使用私有数据库的 Custom Zone
let zoneID = CKRecordZone.ID(zoneName: "UserData", ownerName: CKCurrentUserDefaultName)
let zone = CKRecordZone(zoneID: zoneID)

// 启用 Zone 订阅以支持跨设备通知
let subscription = CKRecordZoneSubscription(zoneID: zoneID)
subscription["notificationID"] = "user-data-changes"
```

---

## 四、同步流程设计

### 4.1 首次同步

```
┌─────────────────────────────────────────────────────────────┐
│                    首次同步流程                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. App 启动，检测到首次使用                                │
│                                                              │
│  2. 创建 Custom Zone: "UserData"                           │
│                                                              │
│  3. 全量拉取 CloudKit 数据                                  │
│                                                              │
│  4. 合并到本地 SQLite                                      │
│                                                              │
│  5. 记录 lastSyncToken                                    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 增量同步

```swift
// 增量同步伪代码
func performIncrementalSync() async throws {
    // 1. 保存本地变更到 CloudKit
    let localChanges = try database.fetchPendingChanges()
    for change in localChanges {
        try await cloudKit.save(change)
    }

    // 2. 从 CloudKit 拉取远程变更
    let serverChanges = try await cloudKit.fetchChanges(
        since: lastSyncToken
    )

    // 3. 合并远程变更到本地
    for record in serverChanges {
        switch record.recordType {
        case "Tag":
            try mergeTag(record)
        case "RepoNote":
            try mergeRepoNote(record)
        // ...
        case "Tombstone":
            try applyTombstone(record)
        default:
            break
        }
    }

    // 4. 更新 SyncToken
    lastSyncToken = serverChanges.serverChangeToken
}
```

### 4.3 冲突解决

```swift
// 冲突解决：Last-Write-Wins
func mergeRepoNote(local: RepoNote, remote: CKRecord) throws {
    if local.modifiedAt > remote["modifiedAt"] as! Date {
        // 本地更新，更新远程
        try await cloudKit.save(local.toCKRecord())
    } else {
        // 远程更新，更新本地
        local.content = remote["content"] as! String
        local.modifiedAt = remote["modifiedAt"] as! Date
        try database.save(local)
    }
}
```

---

## 五、订阅与通知

### 5.1 订阅类型

```swift
// 1. Zone Subscription - 监听整个 UserData Zone 变化
let zoneSubscription = CKRecordZoneSubscription(
    zoneID: zoneID,
    subscriptionID: "user-data-changes"
)

// 2. 通知配置
let notificationInfo = CKSubscription.NotificationInfo()
notificationInfo.shouldSendContentAvailable = true  // 静默推送

zoneSubscription.notificationInfo = notificationInfo
```

### 5.2 推送处理

```swift
// AppDelegate 或 SceneDelegate 中处理
func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    let notification = CKNotification(fromRemoteNotificationDictionary: userInfo)

    if notification?.subscriptionID == "user-data-changes" {
        Task {
            do {
                try await performIncrementalSync()
                completionHandler(.newData)
            } catch {
                completionHandler(.failed)
            }
        }
    }
}
```

---

## 六、性能优化

### 6.1 批量操作

```swift
// 使用 CKModifyRecordsOperation 批量提交
let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
operation.savePolicy = .changedKeys
operation.qualityOfService = .userInitiated

// 批量大小建议 50-100 条
operation.perRecordSaveBlock = { recordID, result in
    // 处理单个记录保存结果
}
```

### 6.2 离线支持

```swift
// 本地操作队列
class OfflineQueue {
    var pendingOperations: [SyncOperation] = []

    func add(_ operation: SyncOperation) {
        pendingOperations.append(operation)
        persistToDisk()  // 保存到 UserDefaults 或文件
    }

    func process() async throws {
        guard await NetworkMonitor.shared.isConnected else { return }

        for operation in pendingOperations {
            try await process(operation)
        }
        pendingOperations.removeAll()
    }
}
```

### 6.3 数据压缩

```swift
// 对于大文本（如长笔记），可以压缩后再存储
import Compression

func compressNote(_ note: String) -> Data? {
    return note.data(using: .utf8)?.compressed(using: .lzfse)
}

func decompressNote(_ data: Data) -> String? {
    guard let decompressed = try? data.decompressed(using: .lzfse) else {
        return nil
    }
    return String(data: decompressed, encoding: .utf8)
}
```

---

## 七、错误处理

### 7.1 常见错误

| 错误 | 处理策略 |
|------|---------|
| `CKError.networkUnavailable` | 缓存到离线队列，稍后重试 |
| `CKError.serverRecordChanged` | 冲突，按 Last-Write-Wins 处理 |
| `CKError.partialFailure` | 部分成功，处理失败的记录 |
| `CKError.quotaExceeded` | 提示用户清理空间 |

### 7.2 重试策略

```swift
// 指数退避重试
func retryWithBackoff<T>(_ operation: () async throws -> T, maxRetries: Int = 3) async throws -> T {
    var lastError: Error?

    for attempt in 0..<maxRetries {
        do {
            return try await operation()
        } catch {
            lastError = error
            let delay = pow(2.0, Double(attempt))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    throw lastError ?? GenericError.unknown
}
```

---

## 八、Release 订阅通知

### 8.1 Release 监测方案

> **说明**：GitHub 没有 WebSocket 或 Webhook 订阅接口供客户端应用直接使用。使用轮询方案检测 Release 变化。

```swift
/// Release 订阅通知监测
/// 使用 BGAppRefreshTask 在后台定期执行（建议每 4-6 小时一次）
class ReleaseMonitor {
    private let githubAPI: GitHubAPIClient
    private let database: DatabaseManager

    /// 检测所有订阅仓库的新 Release
    func checkForNewReleases() async -> [ReleaseNotification] {
        let subscriptions = database.getActiveSubscriptions()
        var notifications: [ReleaseNotification] = []

        for subscription in subscriptions {
            if let notification = await checkRepo(subscription) {
                notifications.append(notification)
            }
        }

        return notifications
    }
}
```

### 8.2 通知推送

```swift
/// 使用 UNUserNotificationCenter 推送通知
func sendReleaseNotification(_ release: ReleaseNotification) async {
    let content = UNMutableNotificationContent()
    content.title = "\(release.repo.name) 发布新版本"
    content.body = "\(release.release.tagName): \(release.release.name ?? "查看详情")"
    content.sound = .default
    content.userInfo = [
        "repoId": release.repo.id,
        "releaseUrl": release.release.htmlUrl
    ]

    let request = UNNotificationRequest(
        identifier: "release-\(release.repo.id)-\(release.release.id)",
        content: content,
        trigger: nil
    )

    try? await UNUserNotificationCenter.current().add(request)
}
```

---

## 九、后续完善点

- [ ] 实现完整的 ConflictResolver
- [ ] 实现 OfflineQueue 的持久化
- [ ] 实现订阅通知的完整处理
- [ ] 实现 Release 订阅通知监测
- [ ] 编写单元测试
- [ ] 性能测试与优化

---

## 十、多账号 CloudKit 同步预研（2026-06-12 D-30 配套）

> 背景：D-30（2026-06-12）落地多账号本地 DB 物理隔离 —— 同一台 Mac 上同一个 macOS 账号可登录多个 GitHub 账号，每个 GitHub 账号一份独立 SQLite 在 `users/<userId>/starcat.sqlite`。但 CloudKit 当前还只是 placeholder 注释（设计已落但未真正接入），D-30 改造完后必须先想清楚多账号场景下 CloudKit 怎么分区，再开工接入。本节是**预研笔记**，不是最终设计，**真正接入 CloudKit 时需重新拍板**。

### 10.1 问题陈述

CloudKit 的 Private Database 是按 **iCloud 账号**（系统级 Apple ID）分区的，而 Starcat 的"账号"是 **GitHub 账号**（应用级）。同一个 iCloud 账号下登录多个 GitHub 账号时，私有数据库必然共用，需要在 record 层面再做一层逻辑分区。

最简单的反例：dong4j 在自己的 iCloud 账号下，先用 GitHub 工作号 A 登录、给 repo X 打了 `工作` 标签同步到 CloudKit；然后切到 GitHub 个人号 B 登录 —— 如果不做分区，B 账号会拉到 A 的 `工作` 标签 + A 的私人笔记，**严重的数据隔离失败**。

### 10.2 候选策略对比

| 策略 | 实现要点 | 优点 | 缺点 | 推荐度 |
|------|---------|------|------|--------|
| **A. github_user_id 作 partition key** | 每个 record（Tag / RepoNote / RepoStatus 等）新增 `github_user_id: Int64` 字段；查询 / sync 都用 predicate `github_user_id == X` 过滤 | 单 zone 简单；不动 zone 配置；CloudKit storage 不重复 | 客户端必须严格按 user_id 过滤，漏 predicate 直接撕裂账号；CloudKit Indexes 必须给 user_id 加 Queryable index；冲突解决要考虑跨账号 | ⭐⭐⭐ |
| **B. 每账号独立 Zone** | `CKRecordZone(zoneName: "user_<userId>")`；同步 token 也按 zone 分别持久化 | 物理隔离最干净；账号切换不需要客户端 filter；可用 zone 级 `CKFetchRecordZoneChangesOperation` 高效增量同步 | 多账号下 zone 数膨胀（一般 ≤ 5 个 OK，几十个就要小心 CloudKit 配额）；登出 + 切账号 = 切 zone（subscriptions / token 都得切）；初次接入复杂度高 | ⭐⭐⭐⭐ |
| **C. 完全不跨账号同步**（用户多账号 = 多设备各自管） | CloudKit 只同步「当前登录账号」的数据；切账号 = 暂停同步 + 标记 stale；不在 CloudKit 上存任何 user_id 区分 | 极简实现；客户端无 partition 心智负担 | 用户在多设备多账号下不能跨设备同步同一 GitHub 账号的数据（与 iCloud 设计违背）；用户体验差 | ⭐ |
| **D. 让用户在 macOS 系统层切 iCloud 账号** | 不接 CloudKit，要用云同步 = 让用户用不同 macOS 系统账号 | 完全规避 CloudKit 多账号问题 | 用户成本极高；与产品定位（轻量个人工具）冲突 | ⭐ |

### 10.3 倾向方案 B（独立 Zone）+ 设计草案

**核心想法**：每个 GitHub 账号对应一个 `CKRecordZone(zoneName: "user_<github_user_id>")`，所有 Tag / RepoNote / RepoStatus / SavedSearch / RepoTag / Tombstone 等私有 record 都创建到该 zone 下。客户端在登录 / 切账号时只切对应 zone，同步 token / subscriptions 都按 zone 分别管理。

```swift
// CloudKitManager 伪代码
final class CloudKitManager {
    var currentZoneID: CKRecordZone.ID?

    // AppDependencies 在 onUserSessionChanged closure 里调
    @MainActor
    func switchToUser(_ userId: Int64?) async throws {
        guard let userId else {
            // 登出态：停所有 sync subscriptions，不切到任何 zone
            await suspendAllSync()
            currentZoneID = nil
            return
        }

        let zoneName = "user_\(userId)"
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        // 1. 若 zone 不存在，创建（首次登录该 GitHub 账号）
        try await ensureZoneExists(zoneID)
        currentZoneID = zoneID

        // 2. 加载该 zone 的 server change token（按 zone 分别持久化）
        let token = await loadChangeToken(for: zoneID)

        // 3. 启动该 zone 的增量同步
        await startIncrementalSync(zoneID: zoneID, token: token)

        // 4. 启动该 zone 的 subscription（如果没有则创建）
        try await ensureZoneSubscription(zoneID: zoneID)
    }
}
```

**关键约束 / 已知坑**：

1. **同步 token 必须按 zone 隔离持久化**：`CKServerChangeToken` 是 per-zone 的，不能跨 zone 复用。原本的 `UserDefaults.standard.set(token, forKey: "cloudkit_change_token")` 要改成 `forKey: "cloudkit_change_token_user_<userId>"`。
2. **Subscriptions 也按 zone 分别管理**：每个 zone 一份 `CKRecordZoneSubscription`，切账号时旧 zone 的 subscription 可以保留不删（CloudKit 配额允许 50 个 subscription per database），但只激活当前账号的推送处理。
3. **首次登录 GitHub 账号 = 首次创建 zone**：需要捕获 `CKError.zoneNotFound` 走创建路径；同时要处理"用户从 GitHub 撤销了 App 授权 + 重新授权 → 新 user_id（GitHub 不太可能换 id，但权限重授给原 id）"的恢复路径。
4. **Tombstone 也按 zone 隔离**：每个 zone 自己一份 tombstone，跨账号删除互不影响。
5. **CloudKit 配额观察**：Apple 文档没有明确限制 zone 数量，但实际 100+ zone 会拖慢首次同步。Starcat 多账号场景一般 ≤ 5 个 GitHub 账号，远低于风险线，但要在 README / about 页提示用户「多账号会增加 iCloud 存储占用」。
6. **没有"全局共享设置"的 zone**：本来 UserPreferences 这种全局设置可以挂 default zone（CKRecordZone.default()），但 dong4j 的产品设计是 UserPreferences 也按账号隔离（不同账号可以有不同的标签建议提示频率等），所以也走对应 user zone。
7. **AppDependencies 集成点**：D-30 已经准备好 `onUserSessionChanged` closure，CloudKit 接入时只需要给该 closure 追加一个 `await cloudKit.switchToUser(userId)` 调用即可，**架构层零改动**。

### 10.4 与 D-30 落地后的本地 DB 关系

| 维度 | 本地 SQLite（D-30 落地） | CloudKit（多账号预研） |
|------|------------------------|----------------------|
| 隔离粒度 | 文件级（`users/<userId>/starcat.sqlite`） | Zone 级（`user_<userId>`） |
| 切换时机 | AuthSession 4 钩子点 → `DatabaseManager.reopen(userId:)` | 同 4 钩子点 → `CloudKitManager.switchToUser(userId:)` |
| 共享数据 | AI keys、credentials.json（凭证池） | 暂定无；UserPreferences 也按账号隔离 |
| 登出态 | `_anonymous` 占位 DB | 暂停 sync，不切 zone |
| 删除账号语义 | 用户手动 `rm users/<userId>/` 即可 | 调 `CKModifyRecordZonesOperation.delete(zoneID)` 删 zone（含 zone 内全部 records） |

### 10.5 实施 TODO（接 CloudKit 时再启动）

- [ ] 拍板策略 A vs B（强烈倾向 B）
- [ ] 设计 zone 命名规范 + zone 元信息（zoneName / ownerName / 配置）
- [ ] 改造现有 record types 移除 `github_user_id` 字段（如果当初设计了），转 zone 级隔离
- [ ] AppDependencies 集成 `cloudKit.switchToUser(userId)` 调用（接到 onUserSessionChanged closure）
- [ ] 同步 token 持久化改 per-zone（`cloudkit_change_token_user_<userId>`）
- [ ] subscription 改 per-zone 创建 + 推送处理路由
- [ ] 添加 `CKError.zoneNotFound` → 创建 zone 的恢复路径
- [ ] 多账号 e2e 测试（A 同步 → B 登录 → B 不应看到 A 数据 → 切回 A 数据全在 + CloudKit 反向 push 进 A zone）
- [ ] About 页提示用户「多账号同步占用 iCloud 存储」

---

*最后更新：2026-06-12 23:55（追加 §10 多账号 CloudKit 同步预研，配套 D-30）*
