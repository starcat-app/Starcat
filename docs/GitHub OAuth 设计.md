# GitHub OAuth 设计

> 本文档定义 GitHub OAuth 的最小权限配置和实现思路。

---

## 一、OAuth Scope 设计

### 1.1 最小权限 Scope

```swift
// 只需要读取用户 Stars 的权限
let scopes = ["read:user", "public_repo"]
```

| Scope | 说明 | 是否必须 |
|-------|------|---------|
| `read:user` | 读取用户公开信息（ID、用户名、头像） | ✅ 必须 |
| `public_repo` | 读取用户 star 的公开仓库 | ✅ 必须 |
| `user:email` | 读取用户邮箱 | ❌ 可选 |

### 1.2 为什么只需要这些

```
Starcat 只管理公开的 Stars：
├── 读取用户的 Star 列表 ✅ (public_repo)
├── 读取被 Star 的仓库信息 ✅ (public_repo)
├── 读取用户信息 ✅ (read:user)
└── 写入操作（取消 Star）❌ 不需要，应用只读
```

### 1.3 不需要的权限

| Scope | 为什么不需要 |
|-------|------------|
| `repo` | 不需要读写私有仓库 |
| `read:org` | 不需要访问组织 |
| `gist` | 不需要 Gist |
| `notifications` | 不需要通知 |

---

## 二、OAuth 实现流程

### 2.1 授权流程

```
┌─────────────────────────────────────────────────────────────┐
│                    OAuth 授权流程                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. App 生成随机 state，保存本地                              │
│                                                              │
│  2. 打开浏览器：                                            │
│     https://github.com/login/oauth/authorize              │
│     ?client_id=xxx                                        │
│     &scope=read:user,public_repo                         │
│     &state=random_state                                   │
│                                                              │
│  3. 用户在 GitHub 页面点击授权                              │
│                                                              │
│  4. GitHub 回调：                                           │
│     starchat://callback?code=xxx&state=random_state      │
│                                                              │
│  5. App 用 code 换 token：                                 │
│     POST https://github.com/login/occess_token            │
│     { client_id, client_secret, code }                    │
│                                                              │
│  6. 存储 token 到 Keychain                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Token 存储

```swift
// 存储到 Keychain
let tokenData = KeychainManager.shared.storeToken(accessToken)
```

```swift
// Keychain 配置
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.starchat.app",
    kSecAttrAccount as String: "github_access_token",
    kSecValueData as String: tokenData,
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
]
```

### 2.3 Token 刷新

```
GitHub OAuth Token 没有 refresh_token！

┌─────────────────────────────────────────────────────────────┐
│                    Token 过期策略                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  GitHub OAuth Token 有效期：                                 │
│  ├── 有 active sessions：永久有效                           │
│  └── 用户撤销 / 密码更改 / 2FA 问题：过期                    │
│                                                              │
│  处理方式：                                                  │
│  1. API 调用返回 401                                       │
│  2. 清除本地 token                                         │
│  3. 引导用户重新授权                                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 三、GitHub OAuth App 注册

### 3.1 注册 OAuth App

访问：https://github.com/settings/applications/new

```
Application name: Starcat
Homepage URL: https://starchat.app
Description: GitHub Stars Manager with AI
Authorization callback URL: starchat://callback
```

### 3.2 获取凭据

注册后会获得：
- **Client ID**: 公开信息，用于构建授权 URL
- **Client Secret**: 机密信息，用于后端换 token（**不要暴露在前端**）

### 3.3 注意事项

```
┌─────────────────────────────────────────────────────────────┐
│                    安全注意事项                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Client Secret 必须保护好：                                 │
│  ├── 不能硬编码在 App 中（会被反编译）                     │
│  ├── 不能放在 GitHub 仓库                                    │
│  ├── 不能放在客户端代码中                                    │
│  └── 应该通过服务端代理（或使用安全存储）                    │
│                                                              │
│  推荐方案：                                                  │
│  1. 客户端使用 PKCE 流程（不需要 client_secret）           │
│  2. 或通过你自己的服务器中转 token 交换                    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 四、PKCE 流程（推荐）

### 4.1 为什么用 PKCE

```
传统 OAuth 需要 client_secret 换 token，但：
├── 客户端不能安全存储 secret
├── PKCE 不需要 secret
└── 安全性更高
```

### 4.2 PKCE 实现

```swift
// 1. 生成 code_verifier
func generateCodeVerifier() -> String {
    var buffer = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
    return Data(buffer).base64URLEncodedString()
}

// 2. 生成 code_challenge
func generateCodeChallenge(from verifier: String) -> String {
    let data = Data(verifier.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
        _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return Data(hash).base64URLEncodedString()
}

// 3. 授权 URL
let codeVerifier = generateCodeVerifier()
let codeChallenge = generateCodeChallenge(from: codeVerifier)
let state = UUID().uuidString

// 保存到本地
UserDefaults.standard.set(codeVerifier, forKey: "code_verifier")
UserDefaults.standard.set(state, forKey: "oauth_state")

let authURL = "https://github.com/login/oauth/authorize?" +
    "client_id=\(clientID)&" +
    "scope=read:user,public_repo&" +
    "state=\(state)&" +
    "code_challenge=\(codeChallenge)&" +
    "code_challenge_method=S256"
```

### 4.3 交换 Token

```swift
// 用 code + code_verifier 换 token（不需要 secret）
func exchangeCodeForToken(code: String, codeVerifier: String) async throws -> String {
    let url = URL(string: "https://github.com/login/oauth/access_token")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
        "client_id": clientID,
        "code": code,
        "code_verifier": codeVerifier,
        "grant_type": "authorization_code"
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, _) = try await URLSession.shared.data(for: request)
    let response = try JSONDecoder().decode(GitHubTokenResponse.self, from: data)

    return response.accessToken
}
```

---

## 五、错误处理

### 5.1 常见错误

| 错误 | 说明 | 处理 |
|------|------|------|
| `state mismatch` | CSRF 攻击 | 清除状态，引导重新授权 |
| `code expired` | code 过期（10分钟内有效） | 引导重新授权 |
| `invalid client_id` | Client ID 无效 | 检查配置 |
| `redirect_uri mismatch` | 回调 URL 不匹配 | 检查 GitHub App 配置 |

### 5.2 授权失败处理

```swift
enum AuthError: Error {
    case stateMismatch
    case codeExpired
    case networkError(Error)
    case invalidResponse
    case tokenExchangeFailed
}

func handleAuthError(_ error: AuthError) {
    switch error {
    case .stateMismatch:
        // 可能是 CSRF 攻击，提示安全警告
        showAlert(title: "授权失败", message: "安全验证失败，请重试。")
    case .codeExpired:
        showAlert(title: "授权过期", message: "授权已过期，请重新授权。")
    case .networkError:
        showAlert(title: "网络错误", message: "网络连接失败，请检查网络后重试。")
    case .tokenExchangeFailed:
        showAlert(title: "授权失败", message: "获取访问令牌失败，请重试。")
    case .invalidResponse:
        showAlert(title: "授权失败", message: "服务器响应无效，请重试。")
    }

    // 清除本地状态
    clearAuthState()
}
```

---

## 六、后续完善点

- [ ] 实现完整的 PKCE 流程
- [ ] 实现 Token 过期自动重新授权
- [ ] 实现 GitHub App（支持 Webhook 等高级功能）
- [ ] 编写单元测试

---

*最后更新：2026-05-29*
