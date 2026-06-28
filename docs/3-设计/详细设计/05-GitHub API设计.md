# GitHub API 设计

> 本文档定义 GitHub API 的调用设计，包括端点、Rate Limit 处理、同步策略。

---

## 一、OAuth 配置

### 1.1 需要的 Scope

```swift
// 只需要读取用户 Stars 的权限
let scopes = ["read:user", "public_repo"]
```

| Scope | 说明 | 是否必须 |
|-------|------|---------|
| `read:user` | 读取用户信息 | ✅ 必须 |
| `public_repo` | 访问公共仓库的 Stars | ✅ 必须 |

### 1.2 PKCE 流程

```
┌─────────────────────────────────────────────────────────────┐
│                    OAuth PKCE 流程                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. App 生成 code_verifier + code_challenge                  │
│                                                              │
│  2. 打开浏览器：                                         │
│     https://github.com/login/oauth/authorize              │
│     ?client_id=xxx                                        │
│     &scope=read:user,public_repo                         │
│     &code_challenge=xxx                                   │
│                                                              │
│  3. GitHub 回调：                                         │
│     starcat://callback?code=xxx                           │
│                                                              │
│  4. 用 code + code_verifier 换 token（不需要 secret）      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 Token 存储

```swift
// 存储到 Keychain
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.starcat.app",
    kSecAttrAccount as String: "github_access_token",
    kSecValueData as String: tokenData,
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
]
```

---

## 二、API 端点设计

### 2.1 端点列表

```swift
enum GitHubAPI {
    // Stars
    case starredRepos(page: Int, perPage: Int)  // GET /user/starred
    case isStarred(owner: String, repo: String)  // GET /user/starred/{owner}/{repo}
    case unstar(owner: String, repo: String)     // DELETE /user/starred/{owner}/{repo}

    // Repos
    case repo(owner: String, repo: String)       // GET /repos/{owner}/{repo}
    case readme(owner: String, repo: String)     // GET /repos/{owner}/{repo}/readme

    // Releases
    case releases(owner: String, repo: String)   // GET /repos/{owner}/{repo}/releases
    case latestRelease(owner: String, repo: String) // GET /repos/{owner}/{repo}/releases/latest

    // User
    case currentUser()                           // GET /user
    case userEmails()                           // GET /user/emails
}
```

### 2.2 Stars API

```swift
// GET /user/starred
// 分页获取用户 star 的仓库列表
struct StarredReposResponse: Codable {
    let totalCount: Int
    let items: [Repo]?
    let lastPage: Bool?
}

// 请求参数
// page: 页码 (从 1 开始)
// per_page: 每页数量 (最大 100)

// 返回头
// Link: <https://api.github.com/user/starred?page=2>; rel="next", ...
```

### 2.3 Repo API

```swift
// GET /repos/{owner}/{repo}
// 获取仓库详情
struct RepoResponse: Codable {
    let id: Int
    let name: String
    let fullName: String
    let description: String?
    let language: String?
    let stargazersCount: Int
    let forksCount: Int
    let watchersCount: Int
    let topics: [String]?
    let license: License?
    let homepage: String?
    let htmlUrl: String
    let cloneUrl: String
    let sshUrl: String
    let pushedAt: String?
    let createdAt: String
    let updatedAt: String
    let archived: Bool
    let fork: Bool
}

// GET /repos/{owner}/{repo}/readme
// 获取 README（返回 Base64 编码）
struct ReadmeResponse: Codable {
    let name: String
    let content: String  // Base64 encoded
    let encoding: String  // "base64"
}
```

### 2.4 Releases API

```swift
// GET /repos/{owner}/{repo}/releases
struct ReleaseResponse: Codable {
    let id: Int
    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let draft: Bool
    let publishedAt: String
    let htmlUrl: String
    let assets: [ReleaseAsset]
}

struct ReleaseAsset: Codable {
    let id: Int
    let name: String
    let size: Int
    let browserDownloadUrl: String
}
```

---

## 三、Rate Limit 处理

### 3.1 限制说明

| 类型 | 限制 | 说明 |
|------|------|------|
| 未认证 | 60 req/hour | IP 级别 |
| OAuth | 5,000 req/hour | 用户级别 |

### 3.2 Rate Limit Handler

```swift
struct RateLimitHandler {
    let maxRequestsPerHour = 5000  // OAuth 限制

    func shouldRetry(after response: HTTPURLResponse) -> TimeInterval? {
        guard response.statusCode == 403 else { return nil }

        // 检查 X-RateLimit-Remaining header
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           remaining == "0" {
            // 计算重试时间
            if let resetStr = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let reset = TimeInterval(resetStr) {
                let resetDate = Date(timeIntervalSince1970: reset)
                return resetDate.timeIntervalSinceNow
            }
        }
        return nil
    }

    // 解析 Link header 获取分页信息
    func parseLinkHeader(_ link: String?) -> (next: Int?, last: Int?) {
        guard let link = link else { return (nil, nil) }

        var nextPage: Int?
        var lastPage: Int?

        // Link: <https://api.github.com/user/starred?page=2>; rel="next", ...
        let components = link.components(separatedBy: ",")
        for component in components {
            let pair = component.components(separatedBy: ";")
            guard pair.count == 2 else { continue }

            let urlPart = pair[0].trimmingCharacters(in: .whitespaces)
            let relPart = pair[1].trimmingCharacters(in: .whitespaces)

            guard urlPart.hasPrefix("<") && urlPart.hasSuffix(">") else { continue }

            let urlString = String(urlPart.dropFirst().dropLast())
            guard let url = URL(string: urlString),
                  let page = url.queryParameters?["page"] else { continue }

            if relPart.contains("next") {
                nextPage = Int(page)
            } else if relPart.contains("last") {
                lastPage = Int(page)
            }
        }

        return (nextPage, lastPage)
    }
}

extension URL {
    var queryParameters: [String: String]? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }
        return queryItems.reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value
        }
    }
}
```

### 3.3 重试策略

```swift
// 指数退避重试
func fetchWithRetry<T>(
    request: URLRequest,
    maxRetries: Int = 3
) async throws -> T where T: Decodable {
    var lastError: Error?

    for attempt in 0..<maxRetries {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            // 检查 Rate Limit
            if let retryAfter = rateLimitHandler.shouldRetry(after: httpResponse) {
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                continue
            }

            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            lastError = error
            let delay = pow(2.0, Double(attempt))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    throw lastError ?? NetworkError.unknown
}
```

---

## 四、同步策略

### 4.1 同步类型

| 类型 | 说明 | 触发时机 |
|------|------|---------|
| 全量同步 | 首次同步，拉取所有 stars | 首次登录 |
| 增量同步 | 只拉取变化的 | 定期或手动 |
| 手动刷新 | 用户主动触发完整同步 | 用户点击刷新按钮 |
| 按需同步 | 只拉取当前需要的 | 用户查看详情 |

### 4.2 全量同步流程

```swift
func performFullSync() async throws {
    var page = 1
    let perPage = 100
    var hasMore = true

    while hasMore {
        let repos: [Repo] = try await githubAPI.starredRepos(page: page, perPage: perPage)

        // 批量写入数据库
        try await database.insertRepos(repos)

        // 检查是否还有更多
        hasMore = repos.count == perPage
        page += 1

        // 更新进度
        await updateSyncProgress(page: page, reposLoaded: repos.count)
    }
}
```

### 4.3 增量同步流程

```swift
// 增量同步策略
// 由于 GitHub API 不支持 delta query，我们采用以下策略：

// 方案 1：记录时间戳，定期全量对比
func performIncrementalSync() async throws {
    let lastSyncAt = UserDefaults.standard.string(forKey: "last_sync_at")
    // 拉取所有，然后对比时间戳
    let allRepos = try await githubAPI.starredRepos()

    for repo in allRepos {
        if repo.starredAt > lastSyncAt {
            // 新增或更新
            try await database.upsertRepo(repo)
        }
    }

    // 检测删除（本地有但远程没有）
    let localRepoIds = Set(database.allRepoIds())
    let remoteRepoIds = Set(allRepos.map(\.id))
    let deletedIds = localRepoIds.subtracting(remoteRepoIds)
    try await database.deleteRepos(ids: deletedIds)

    UserDefaults.standard.set(Date().iso8601String, forKey: "last_sync_at")
}

// 方案 2：维护上次同步的 etag，用 Last-Modified 验证
func performIncrementalSyncWithETag() async throws {
    let storedETag = UserDefaults.standard.string(forKey: "stars_etag")

    var request = URLRequest(url: starredReposURL)
    if let etag = storedETag {
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }

    let (data, response) = try await URLSession.shared.data(for: request)

    if let httpResponse = response as? HTTPURLResponse,
       httpResponse.statusCode == 304 {
        // 没有变化，跳过
        return
    }

    // 处理变化的数据
    let repos = try JSONDecoder().decode([Repo].self, from: data)
    try await database.upsertRepos(repos)

    // 更新 ETag
    if let newEtag = httpResponse.value(forHTTPHeaderField: "ETag") {
        UserDefaults.standard.set(newEtag, forKey: "stars_etag")
    }
}
```

### 4.4 按需同步

```swift
// 只在用户点击查看详情时才拉取 README
func fetchReadmeIfNeeded(repo: Repo) async throws -> Readme {
    // 1. 检查本地缓存
    if let cached = database.getCachedReadme(repoId: repo.id) {
        // 2. 验证缓存是否过期（7 天）
        if !cached.isExpired {
            return cached
        }

        // 3. 用 ETag 验证
        let (data, response) = try await githubAPI.readmeWithETag(repo: repo, etag: cached.etag)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 304 {
            // 4. 缓存有效，更新缓存时间
            database.updateReadmeCacheTime(repo.id)
            return cached
        }

        // 5. 有更新，解析新内容
        let readme = try decodeReadme(from: data)
        database.saveReadme(readme)
        return readme
    }

    // 6. 没有缓存，直接拉取
    let readme = try await githubAPI.readme(repo: repo)
    database.saveReadme(readme)
    return readme
}
```

---

## 五、错误处理

### 5.1 常见错误

| HTTP 状态 | 错误 | 处理 |
|-----------|------|------|
| 401 | 未授权 | 清除 token，引导重新登录 |
| 403 | Rate Limited | 等待后重试 |
| 404 | 仓库不存在 | 标记为已删除 |
| 500 | GitHub 服务器错误 | 指数退避重试 |

### 5.2 网络错误

```swift
enum NetworkError: Error {
    case invalidURL
    case invalidResponse
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    case notFound
    case serverError(statusCode: Int)
    case decodingError(Error)
    case networkError(Error)
}

func handleError(_ error: Error) async {
    switch error {
    case let error as NetworkError:
        switch error {
        case .unauthorized:
            await handleUnauthorized()
        case .rateLimited(let retryAfter):
            await handleRateLimited(retryAfter: retryAfter)
        case .networkError:
            await showNetworkError(error)
        default:
            await showGenericError(error)
        }
    default:
        await showGenericError(error)
    }
}
```

---

*最后更新：2026-05-29*
