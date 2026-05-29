# CloudKit 数据同步设计

> 本文档定义 CloudKit 的 Schema 设计，用于多端用户数据同步。
>
> **设计思路**：用户数据优先，云端为本。仅同步用户生成数据，不同步可重建的缓存数据。

---

## 一、设计原则

### 1.1 数据分类

| 数据类型 | 是否同步 | 说明 |
|---------|---------|------|
| Tags | ✅ 同步 | 用户创建的标签 |
| RepoNotes | ✅ 同步 | 用户写的笔记 |
| RepoStatus | ✅ 同步 | 阅读状态 |
| SavedSearches | ✅ 同步 | 保存的搜索 |
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

## 八、后续完善点

- [ ] 实现完整的 ConflictResolver
- [ ] 实现 OfflineQueue 的持久化
- [ ] 实现订阅通知的完整处理
- [ ] 编写单元测试
- [ ] 性能测试与优化

---

*最后更新：2026-05-29*
