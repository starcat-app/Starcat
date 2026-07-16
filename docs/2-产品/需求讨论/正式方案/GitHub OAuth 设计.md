# GitHub OAuth 设计

> Starcat 三种 GitHub 登录方式（Web Application Flow / Device Flow / PAT 直接输入）的设计文档。
> 本文档同时记录 PAT 直接登录与 Web Application Flow 的实现技术规范。

---

## 一、背景与目标

Starcat 需要访问用户的 GitHub Stars 数据。GitHub 提供了多种「让用户授权」的方式，**每种方式的 UX 体验、安全模型、工程成本都不一样**。本文档：

1. 对比 Web Application Flow 与 Device Flow 的概念、优缺点、适用场景
2. 给出 Starcat 三种登录方式的代码位置与状态机
3. 明确 Device Flow 仍是默认入口，PAT 与 Web Application Flow 由用户主动选择

### 1.1 三种登录方式概览

| 方式 | 协议位置 | Starcat 状态 |
|---|---|---|
| **Web Application Flow**（Authorization Code + PKCE） | OAuth 2.0 RFC 6749 §4.1 + RFC 7636（PKCE） | ✅ 可选方式（ASWebAuthenticationSession） |
| **Device Flow** | OAuth 2.0 RFC 8628（GitHub 自定义端点） | ✅ **当前默认**（2026-05 落地） |
| **PAT 直接输入** | 非 OAuth（用户手动生成 GitHub Personal Access Token） | ✅ 可选方式 |

### 1.2 术语表

- **OAuth App** — GitHub 颁发的应用标识（`Client ID` 公开、`Client Secret` 机密）
- **Authorization Code** — Web Flow 里的中间凭证，10 分钟内有效，用 `code` + `client_secret`（或 `code_verifier`）换 `access_token`
- **device_code / user_code** — Device Flow 里的两类 code：`device_code` 客户端用、`user_code` 用户在 GitHub 网站输入
- **PKCE**（Proof Key for Code Exchange, RFC 7636）— Web Flow 的安全扩展，用 `code_verifier` + `code_challenge` 防止 authorization code 被截获
- **PAT**（Personal Access Token）— GitHub 用户在 Settings → Developer settings → Personal access tokens 手动生成的长效 token（40 字符，前缀 `ghp_*` / `github_pat_*`）
- **client_secret** — OAuth App 的机密凭据，**绝对不能放客户端**

---

## 二、OAuth Scope 设计

### 2.1 最小权限 Scope

```swift
let scopes = ["read:user", "public_repo"]
```

| Scope | 说明 | 是否必须 |
|-------|------|---------|
| `read:user` | 读取用户公开信息（ID、用户名、头像） | ✅ 必须 |
| `public_repo` | 访问公共仓库的 Stars（包含 star/unstar 权限） | ✅ 必须 |
| `user:email` | 读取用户邮箱 | ❌ 可选 |

### 2.2 为什么只需要这些

```
Starcat 需要以下能力：
├── 读取用户的 Star 列表 ✅ (public_repo)
├── 读取被 Star 的仓库信息 ✅ (public_repo)
├── 读取用户信息 ✅ (read:user)
└── 取消 Star ✅ (public_repo) - DELETE /user/starred/{owner}/{repo}
```

> **说明**：`public_repo` scope 已包含对公开仓库的 star/unstar 操作权限，不需要 `repo` scope。

### 2.3 三种方式共享同一份 Scope

Web Flow / Device Flow / PAT 三种方式的 scope 列表完全一致——它们拿到的都是同一类 `access_token`，调 `GET /user` 都用 `read:user`、调 Stars API 都用 `public_repo`。**scope 设计与登录方式正交**。

---

## 三、Web Application Flow（Authorization Code）

> 状态：✅ 已实现。2026-07-16 起授权页面由 `ASWebAuthenticationSession` 承载。

### 3.1 流程

```
┌─────────────────────────────────────────────────────────────┐
│                  Web Application Flow                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. App 生成 state + (可选) code_verifier, 保存本地         │
│                                                              │
│  2. ASWebAuthenticationSession 展示授权页：                 │
│     https://github.com/login/oauth/authorize              │
│     ?client_id=xxx                                        │
│     &scope=read:user,public_repo                         │
│     &state=random_state                                   │
│     &code_challenge=<S256(verifier)>   ← PKCE              │
│     &code_challenge_method=S256                           │
│     &redirect_uri=starcat://callback                      │
│                                                              │
│  3. 用户在 GitHub 页面点击 Authorize                        │
│                                                              │
│  4. 系统认证会话截获 GitHub 回调：                          │
│     starcat://callback?code=xxx&state=random_state       │
│                                                              │
│  5. App 用 code + code_verifier 换 token：                │
│     POST https://github.com/login/oauth/access_token      │
│     { client_id, code, code_verifier }  ← 不需要 secret    │
│                                                              │
│  6. 存储 token 到 Keychain                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 安全变体：PKCE vs 后端代理

Web Flow 有两种安全实现方式，**starcat 计划 W6 二选一**：

| 变体 | 是否需要 client_secret | 何时必须 |
|---|---|---|
| **PKCE（推荐）** | ❌ 不需要 | Starcat 客户端直接走 OAuth，**没有自己的后端代理**时 |
| **后端代理** | ✅ 后端持有 | Starcat 有后端代理服务（类似 `github-store.org/auth/callback` 模式），后端用 `client_secret` 换 token，**客户端不碰 secret** |

```
Web Application Flow 安全变体
├── ① 纯前端 + PKCE（无后端）
│   ├── 客户端：生成 code_verifier、code_challenge
│   ├── /authorize URL 必须带 code_challenge
│   ├── /access_token 提交 code_verifier
│   └── 安全性来自 verifier 永远不离开客户端
│
└── ② 后端代理 + client_secret（有后端）
    ├── 客户端：仅生成 state
    ├── 跳 /authorize，URL 不带 code_challenge
    ├── GitHub 回调到后端 https://api.starcat.app/auth/callback
    ├── 后端用 code + client_secret 换 token
    └── token 透传给客户端（走 HTTPS）
```

### 3.3 优缺点

**优点**
- 体验最完整：浏览器授权 → 一次性回调 → 立即登录，无中间态
- 兼容 GitHub OAuth App 默认行为（所有 GitHub App 都支持）
- PKCE 模式无后端也能安全做（适合 0 后端成本的客户端）
- 自动拿到 refresh_token 能力（GitHub OAuth App 当前**不**返回 refresh_token，但 Web Flow 流程最接近「OAuth 标准」）

**缺点**
- 需要 GitHub OAuth App 注册并填 callback URL（iOS / macOS App 走 `starcat://` custom scheme 或 universal link）
- PKCE 模式无后端 → client_secret 暴露风险（GitHub 2022-11 起新 OAuth App 强制 PKCE 校验）
- 后端代理模式需要维护额外服务（域名、HTTPS、密钥）
- macOS 沙盒 + custom scheme 的回调接收需要 `Info.plist` 注册 URL types
- Debug 期 `starcat://` 回调要单独测（首次启动 OS 会弹权限）

### 3.4 适用场景

- **PKCE**：客户端有 Client ID、无后端代理、想走「标准 OAuth」体验
- **后端代理**：已有后端 / 不想在客户端存任何凭据 / 需要服务端审计授权事件
- **不适用场景**：没有 GitHub OAuth App（Client ID 是占位）、不想配置 callback URL

### 3.5 Starcat 计划

| 阶段 | 工作 |
|---|---|
| **W6 之前** | 文档沉淀（本节），不写代码 |
| **W6 触发条件** | ① GitHub OAuth App 注册完成 + ② 选定 PKCE 或后端代理（取决于后端就绪状态） |
| **实现要点** | ① 新增 `GithubWebFlowService: GithubOAuthServiceProtocol` 第二个 grant type；② `AuthSession.state` 新增 `.awaitingWebCallback(code)` 中间态；③ `GithubAuthView` 拆分 `awaitingWebCallbackView`；④ `Info.plist` 注册 `starcat://` URL scheme；⑤ 单测覆盖 4 条路径：state 校验失败 / code 过期 / token 交换失败 / 成功 |

---

## 四、Device Flow（当前默认）

> 状态：✅ 2026-05 落地为生产版本，**当前 Starcat 的默认登录方式**。

### 4.1 流程

```
┌─────────────────────────────────────────────────────────────┐
│                      Device Flow                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 客户端 POST /login/device/code                          │
│     body: { client_id, scope }                              │
│     resp: { device_code, user_code, verification_uri,       │
│              expires_in, interval }                          │
│                                                              │
│  2. UI 展示 user_code，引导用户：                            │
│     - 打开 https://github.com/login/device                │
│     - 输入 user_code 点 Authorize                           │
│                                                              │
│  3. 客户端按 interval 秒间隔轮询                             │
│     POST /login/oauth/access_token                         │
│     body: { client_id, device_code,                         │
│             grant_type=urn:ietf:params:oauth:              │
│                       grant-type:device-code }              │
│     resp: { access_token, token_type, scope }              │
│                                                              │
│  4. 存储 token 到 Keychain                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 优缺点

**优点**
- **不需要 client_secret**（设备是用户操作的，code 不会离开设备）—— 天然规避 secret 泄露
- **不需要 callback URL** —— 不依赖 `starcat://` 或后端域名，**macOS 沙盒零配置**
- 用户体验对开发者友好：「打开 GitHub → 输 8 位 code → 完成」，不打断工作流
- GitHub 官方支持的 OAuth 2.0 扩展（RFC 8628），合规且长期维护

**缺点**
- **用户体验多一步**（输 code），比 Web Flow 多 30-60 秒
- 必须显示 user_code + 引导用户开浏览器（在 macOS 上要弹窗 + 自动打开 URL）
- 需要在 GitHub OAuth App Settings 显式启用「Enable Device Flow」（默认关闭）
- 没有 refresh_token（GitHub OAuth App 不返回），token 失效需重新走一遍
- 错误码在 HTTP 200 + body 字段（`authorization_pending` / `slow_down` / `expired_token` / `access_denied`），跟常规 OAuth 4xx 错误模式不同

### 4.3 适用场景

- **首选**：macOS 客户端应用、无后端代理、不想暴露 client_secret
- **首选**：开发期 Client ID 未注册时的过渡方案（device flow 端点用同样的 Client ID）
- **不适用场景**：要求「一键浏览器授权」体验的产品、已经有 Web 后端的服务

### 4.4 Starcat 当前实现

#### 4.4.1 协议层

**文件**：`Starcat/Features/Auth/GithubOAuthServiceProtocol.swift`

```swift
protocol GithubOAuthServiceProtocol: Sendable {
    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo
    func awaitAccessToken() async throws -> String
    func reset() async
}
```

`OAuthDeviceCodeInfo` 包含 `userCode` / `verificationURI` / `expiresIn` / `pollInterval` 四个字段，供 UI 第一阶段展示。

#### 4.4.2 真实实现

**文件**：`Starcat/Features/Auth/GithubDeviceFlowService.swift`（actor）

- `beginDeviceFlow()`：POST `/login/device/code`，校验 Client ID 非占位，保存 `deviceCode` / `pollInterval` / `expiresAt` 到 actor 状态
- `awaitAccessToken()`：循环 `pollOnce()`，按 `pollInterval` 间隔轮询，命中 `slow_down` 时 `interval += 5`（GitHub 协议要求）
- 关键约束：GitHub 端点在 `github.com`（不是 `api.github.com`）、必须显式 `Accept: application/json`、错误时仍返回 HTTP 200

#### 4.4.3 Mock 实现

**文件**：`Starcat/Features/Auth/MockGithubOAuthService.swift`

DEBUG 模式默认装配，单元测试也用。返回固定 `MOCK-DEV` user_code + `mock_dev_token_xxx` token。

#### 4.4.4 状态机

**文件**：`Starcat/Features/Auth/AuthSession.swift`

```swift
enum AuthState: Equatable {
    case unauthenticated
    case awaitingUserCode(OAuthDeviceCodeInfo)   // Device Flow 第一阶段
    case authenticated(user: GitHubUserDTO)
}
```

`runDeviceFlow()` 三阶段：
1. `beginDeviceFlow()` → emit `.awaitingUserCode(info)`
2. `awaitAccessToken()` → `keychain.storeGithubToken(token)`
3. `apiClient.getCurrentUser()` → emit `.authenticated(user)` + DB 切到该 user

#### 4.4.5 UI

**文件**：`Starcat/Features/Auth/GithubAuthView.swift`

- `awaitingUserCodeView(info:)`：code 卡片 + cancel 按钮 + ProgressView
- `codeButton(info:)`：点击主区触发 `copyAndOpenBrowser`（复制 user_code + 1.5s 后打开 `verificationURI`）
- 复制反馈三态：`.idle` / `.copiedAndOpening` / `.copiedSilent`（详见文件内注释）

#### 4.4.6 装配

**文件**：`Starcat/App/AppDependencies.swift`

`oauthService: any GithubOAuthServiceProtocol` 由依赖注入容器提供（生产用 `GithubDeviceFlowService`，单测用 `MockGithubOAuthService`）。

---

## 五、PAT 直接输入（新增，2026-06-29）

> 状态：🔜 本次落地（与「其他登录方式」入口同期）。

### 5.1 流程

```
┌─────────────────────────────────────────────────────────────┐
│                  PAT 直接输入                                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 用户在 GitHub 手动生成 PAT：                            │
│     Settings → Developer settings →                        │
│     Personal access tokens → Tokens (classic)               │
│     或 Fine-grained tokens                                  │
│     scope: public_repo, read:user                          │
│                                                              │
│  2. 用户在 Starcat 登录页点「其他登录方式」                 │
│     → 展开「使用 Personal Access Token」                     │
│     → 粘贴 PAT 到 SecureField（支持明文切换）              │
│     → 点「使用此 Token 登录」                              │
│                                                              │
│  3. Starcat 临时把 token 写入 Keychain：                    │
│     keychain.storeGithubToken(token)                        │
│                                                              │
│  4. Starcat 拉 GET /user 验证：                             │
│     - 200 → 保留 token、emit .authenticated(user)          │
│     - 401 → 回滚 token、lastError=invalidToken             │
│     - 403 → 回滚 token、lastError=insufficientScope        │
│     - 网络错 → 回滚 token、lastError=network               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 优缺点

**优点**
- **不依赖 GitHub OAuth App 注册** —— 哪怕 Client ID 是占位也能用
- **零依赖** —— 不需要浏览器、不需要 GitHub 端点、不需要轮询
- **高级用户最熟悉** —— 大量 GitHub 老用户习惯用 PAT 写脚本
- **实现最简** —— 复用 `KeychainManager.storeGithubToken` 已有接口，不引入新的 OAuth 协议实现

**缺点**
- **UX 步骤最多** —— 用户要在 GitHub 网站生成、复制、粘贴、再回 Starcat，至少 4 步
- **scope 不可控** —— 用户可能勾错 scope（比如漏了 `public_repo`），Starcat 只能在错误时提示
- **token 类型多样** —— Classic PAT (`ghp_*`) / Fine-grained PAT (`github_pat_*`) / 旧 OAuth token (`gho_*`)，UI 无法做格式校验（任何前缀都要接受，靠 GitHub 401 兜底）
- **安全责任在用户** —— 泄露等于账号失守，Starcat 无法强制过期
- **不能撤销** —— 用户只能自己在 GitHub 撤销，Starcat 不监听事件

### 5.3 适用场景

- **首选**：开发者本人 / 高级用户，知道怎么生成 PAT
- **首选**：Client ID 未注册时的兜底（Device Flow 失效时的备用入口）
- **首选**：CI / 自动化场景（用户可能已经有 PAT）
- **不适用场景**：普通用户首次登录（应引导走 Device Flow）

### 5.4 Starcat 实现设计

#### 5.4.1 入口

**文件**：`Starcat/Features/Auth/GithubAuthView.swift`（修改）

在主 CTA "Continue with GitHub"（Device Flow）下方加：

```
──────  或选择其他方式  ──────
▸ 使用 Personal Access Token
▸ Web Application Flow
```

- 「使用 Personal Access Token」点击后展开：SecureField（带明文切换）+ 「获取 Token 链接」+ 「使用此 Token 登录」按钮
- 「Web Application Flow」由用户主动选择，授权页通过 `ASWebAuthenticationSession` 展示；主 CTA 仍走 Device Flow

#### 5.4.2 状态机扩展

**文件**：`Starcat/Features/Auth/AuthSession.swift`（修改）

**不**新增 `AuthState` case —— PAT 走"无中间态"路径：

```swift
// 新增方法
func signInWithPAT(_ token: String) async {
    guard !isAuthenticating else { return }
    isAuthenticating = true
    lastError = nil

    do {
        // 1. 临时写入 Keychain
        try keychain.storeGithubToken(token)

        // 2. 拉 /user 验证
        let user = try await apiClient.getCurrentUser()

        // 3. 成功路径：与 runDeviceFlow 尾段对称
        await onUserSessionChanged?(user.id)
        self.state = .authenticated(user: user)
        userProfileService?.acceptFromAuth(user)
        contributionService?.load(login: user.login)
        developerLanguageService?.load(login: user.login)
    } catch NetworkError.unauthorized {
        // 401：回滚 token + 提示
        try? keychain.deleteGithubToken()
        self.lastError = GithubPATError.invalidToken
        self.state = .unauthenticated
    } catch let error as NetworkError where error.httpStatus == 403 {
        // 403：scope 不足
        try? keychain.deleteGithubToken()
        self.lastError = GithubPATError.insufficientScope
        self.state = .unauthenticated
    } catch {
        // 网络错：回滚 token + 提示
        try? keychain.deleteGithubToken()
        self.lastError = error
        self.state = .unauthenticated
    }

    isAuthenticating = false
}
```

#### 5.4.3 关键安全约束

- **验证失败必须回滚 token**（`keychain.deleteGithubToken()`）—— 避免把无效 token 留在 Keychain，下次启动 `restoreSessionIfAvailable` 误以为已登录
- **不强制 prefix 校验**（`ghp_*` / `github_pat_*` / `gho_*` 都接受）—— 靠 GitHub 服务端 401 兜底，避免误杀 Fine-grained PAT
- **SecureField 明文切换**（参考 `AISettingsView` 的 AI Key 输入）—— macOS 上 PAT 40 字符易输错，明文切换是 macOS 习惯
- **不在日志中打印完整 token** —— `AppLog.auth` 仅记录 `length=N` 等元信息

#### 5.4.4 错误本地化

```swift
enum GithubPATError: LocalizedError {
    case invalidToken          // 401：Token 无效或已过期
    case insufficientScope     // 403：权限不足，至少需要 read:user 和 public_repo
    case network(Error)        // 网络错误

    var errorDescription: String? { /* String.l10n(...) */ }
}
```

走现有 `AuthSession.lastError` 通道，UI 在 `errorBanner` 自动渲染。

#### 5.4.5 涉及文件清单

| 文件 | 改动 |
|---|---|
| `Starcat/Features/Auth/AuthSession.swift` | 新增 `signInWithPAT(_:)` + `GithubPATError` 枚举 |
| `Starcat/Features/Auth/GithubAuthView.swift` | 新增「其他登录方式」折叠区 + PAT 表单 UI |
| `Starcat/Localizable.xcstrings` | 新增 `authV2.alternative.*` / `authV2.pat.*` i18n 命名空间 |
| `StarcatTests/AuthSessionPATSignInTests.swift` | 新增 4 条用例：成功 / 401 / 403 / 网络失败 |

---

## 六、三种方式对比

| 维度 | Web Application Flow | Device Flow | PAT 直接输入 |
|---|---|---|---|
| **协议位置** | RFC 6749 §4.1 + RFC 7636 | RFC 8628 | 非 OAuth |
| **是否需要 client_secret** | 可选（PKCE 不需要 / 后端代理需要） | ❌ 不需要 | N/A |
| **是否需要 callback URL** | ✅ 需要（`starcat://` 或后端域名） | ❌ 不需要 | N/A |
| **是否需要浏览器** | ✅ 必需 | ✅ 必需 | ❌ 不需要 |
| **用户体验步骤** | 3 步（点登录 → 浏览器授权 → 自动回调） | 4 步（点登录 → 看 code → 浏览器输 code → 等） | 5 步（GitHub 生成 → 复制 → 粘贴 → 验证） |
| **需要 Client ID 注册** | ✅ 必需 | ✅ 必需 | ❌ 不需要 |
| **Token 类型** | OAuth access token | OAuth access token | PAT（同一类 access token） |
| **能否强制 scope** | ✅ OAuth App 设置锁死 | ✅ OAuth App 设置锁死 | ❌ 用户勾选决定 |
| **多账号切换** | 浏览器切换 | 浏览器切换 | 手动换 token |
| **撤销** | 用户在 GitHub OAuth App 撤销 | 同上 | 用户在 PAT 列表撤销 |
| **实现复杂度** | 高（PKCE 协议 + URL scheme） | 中（轮询 + 状态机） | 低（Keychain + /user 验证） |
| **macOS 沙盒兼容性** | 需注册 URL scheme | ✅ 零配置 | ✅ 零配置 |
| **Starcat 当前状态** | ✅ 可选方式 | ✅ **当前默认** | ✅ 可选方式 |
| **Starcat 适用人群** | 标准 OAuth 用户 | 标准用户 | 开发者 / 高级用户 |

### 6.1 选择决策树

```
用户在 Starcat 登录页
├── 普通用户 → Device Flow（默认 CTA）
├── 开发者 / 有 PAT → 点「其他登录方式」→ PAT 直接输入
├── OAuth App 未注册 → 点「其他登录方式」→ PAT 兜底
└── 用户主动选择 Web Application Flow → 系统认证窗口完成标准 OAuth
```

---

## 七、错误处理

### 7.1 三种方式错误码汇总

| 错误 | Web Flow | Device Flow | PAT |
|---|---|---|---|
| 用户拒绝授权 | `access_denied` 回调 | `access_denied`（HTTP 200 body 字段） | N/A（用户没主动拒绝） |
| 凭证过期 | `code expired`（10 分钟） | `expired_token`（设备码寿命） | N/A（PAT 长期有效直到用户撤销） |
| state 校验失败 | `state mismatch`（CSRF 攻击） | N/A（Device Flow 无 state） | N/A |
| scope 不足 | OAuth App 不会发出 | 同上 | `403 Forbidden` from `/user` |
| token 失效 | `401 Unauthorized` from API | 同上 | 同上 |
| 客户端 secret 错误 | `invalid client` | N/A（无 secret） | N/A |
| 网络错误 | `transport error` | 同上 | 同上 |

### 7.2 统一错误处理

```swift
enum AuthError: Error, LocalizedError {
    // Web Flow
    case stateMismatch            // CSRF 攻击
    case codeExpired              // code 过期（10 分钟）
    case tokenExchangeFailed      // code 换 token 失败

    // Device Flow
    case deviceCodeExpired        // 设备码过期
    case userDeclined             // 用户拒绝

    // PAT
    case invalidToken             // 401
    case insufficientScope        // 403

    // 通用
    case network(underlying: Error)
    case unexpectedResponse(String)
}
```

**统一兜底**：任何登录路径失败时，必须清掉本路径产生的中间态（Device Flow 的轮询 Task、PAT 写入 Keychain 的 token），并把 `state` 切回 `.unauthenticated`，由 UI 渲染 `errorBanner`。

### 7.3 401 集中式处理

`GitHubAPIClient` 已有 `setUnauthorizedHandler` 集中式 401 出口：API 调用收到 401 时自动触发 `invalidateSession()`，跳回登录页。**三种方式共享这一路径**——token 失效体验一致。

---

## 八、后续完善点

- [x] **实现 Web Application Flow**（PKCE + `ASWebAuthenticationSession`，Device Flow 保持默认）
- [ ] **PAT 设置页管理**（已登录用户在设置页查看 / 更换 / 删除 token）
- [ ] **PAT 撤销监听**（GitHub Webhook 不可用，仅支持「用户主动在 GitHub 撤销后下次启动 401 清掉」）
- [ ] **三种方式统一抽象**（`SignInStrategy` protocol，让 `AuthSession.signIn(strategy:)` 走同一入口）
- [ ] **多账号 PAT 切换**（开发者可能同时维护多个 GitHub 账号的 PAT）
- [ ] **Token 过期自动重授权**（Device Flow / Web Flow 支持 refresh_token 后实现）

---

## 附录 A：相关代码清单

| 模块 | 文件 |
|---|---|
| OAuth 协议 | `Starcat/Features/Auth/GithubOAuthServiceProtocol.swift` |
| Device Flow 真实实现 | `Starcat/Features/Auth/GithubDeviceFlowService.swift` |
| Device Flow Mock | `Starcat/Features/Auth/MockGithubOAuthService.swift` |
| Web Flow 系统认证窗口 | `Starcat/Features/Auth/WebAuthenticationSession.swift` |
| 状态机 | `Starcat/Features/Auth/AuthSession.swift` |
| 登录 UI | `Starcat/Features/Auth/GithubAuthView.swift` |
| 装配 | `Starcat/App/AppDependencies.swift` |
| Token 存储 | `Starcat/Core/Keychain/KeychainManager.swift`（已有 `storeGithubToken` / `loadGithubToken` / `deleteGithubToken`） |
| 401 集中处理 | `Starcat/Core/Network/GitHubAPI/GitHubAPIClient.swift`（`setUnauthorizedHandler`） |

## 附录 B：相关规范文档

- [`docs/5-规范/UI-颜色规范.md`](../../../5-规范/UI-颜色规范.md) — 错误文案用 `.red`（主色 / 警示色）
- [`docs/5-规范/UI-设置页按钮对齐-规范.md`](../../../5-规范/UI-设置页按钮对齐-规范.md) — PAT 提交按钮走「设置页右对齐」规范
- [`docs/5-规范/国际化-规范.md`](../../../5-规范/国际化-规范.md) + [`docs/5-规范/i18n-军规.md`](../../../5-规范/i18n-军规.md) — 文案走 `String.l10n("authV2.pat.xxx")`

---

*最后更新：2026-06-29*
