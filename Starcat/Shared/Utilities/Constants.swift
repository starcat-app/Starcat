//
//  Constants.swift
//  Starcat
//
//  全局常量集中地。
//
//  关键约束：
//  - Bundle ID / URL scheme / OSLog subsystem 必须保持三者一致（com.starcat.app / starcat）
//  - 网络 endpoint 仅放 base URL，具体路径在 GitHubAPI 端点枚举里拼接
//  - 不放可变状态；如需用户可配置项，走 UserDefaults 或 Settings
//

import Foundation

/// 应用级常量。
///
/// 不可实例化，只暴露静态成员。
enum AppConstants {

    // MARK: - 应用标识

    /// Bundle Identifier，与 Xcode build setting `PRODUCT_BUNDLE_IDENTIFIER` 保持一致。
    /// Keychain service / OSLog subsystem / 沙盒目录命名均依赖此值。
    static let bundleIdentifier = "com.starcat.app"

    /// OSLog subsystem，与 `bundleIdentifier` 保持同名以便 Console.app 过滤。
    static let logSubsystem = bundleIdentifier

    /// 数据库文件名（位于应用沙盒 Application Support 目录）。
    static let databaseFileName = "starcat.sqlite"

    // MARK: - 多账号目录布局（2026-06-12 多账号 DB 隔离）
    //
    // 同一台 Mac 上同一个 macOS 账号可以登录多个 GitHub 账号。
    // 每个 GitHub 账号一份独立的 SQLite 数据库，物理隔离避免串数据：
    //   ~/Library/Application Support/com.starcat.app/
    //   └── users/
    //       ├── _anonymous/                    ← 未登录占位（避免 nil 特判）
    //       │   └── starcat.sqlite
    //       └── <github_user_id>/              ← 已登录用户（按 GitHub User ID）
    //           ├── starcat.sqlite (+ .wal/.shm)
    //           └── _meta.json                 ← {"login":"...", "last_at":"..."}
    //
    // 用 GitHub User ID（Int64）而非 login 作为目录名：用户改 GitHub 用户名后
    // ID 不变，目录路径稳定；login 可能因为用户改名导致目录错位。

    /// 多账号目录的父目录名（与 bundle 目录同级）。
    static let usersDirectoryName = "users"

    /// 未登录占位目录名（前缀 `_` 避免与真实 GitHub user id 冲突）。
    static let anonymousUserDirectoryName = "_anonymous"

    /// 用户目录下的诊断元信息文件名（仅给开发者 Finder 查看用，运行时不读）。
    static let userMetaFileName = "_meta.json"

    // MARK: - GitHub OAuth

    /// OAuth 回调 URL scheme，必须与 Info.plist `CFBundleURLSchemes` 一致。
    static let oauthCallbackScheme = "starcat"

    /// OAuth 回调完整 URL（GitHub OAuth App 注册时填这个）。
    static let oauthCallbackURL = "\(oauthCallbackScheme)://callback"

    /// GitHub OAuth App Client ID。
    /// 公开常量（非 secret），所有 Starcat 用户共用此 ID 走 Device Flow。
    /// 注册入口：https://github.com/settings/applications/new
    /// 必须勾选 "Enable Device Flow"，否则 /login/device/code 返回 403。
    static let githubOAuthClientID = "Ov23li4suXj1nNsWtHHG"

    /// OAuth scope，已最小化（见 docs/2-产品/需求讨论/正式方案/GitHub OAuth 设计.md）。
    static let githubOAuthScopes = ["read:user", "public_repo", "user"]

    /// “我的项目”可选 GitHub App 的公开 Client ID。
    ///
    /// GitHub App 注册属于外部发布 Gate，仓库默认留空仍可编译，并自动退化为 OAuth
    /// public fallback。Client ID 是公开标识，不能与下面的 Client Secret 混用。
    static var githubAppClientID: String {
        let value = Bundle.main.infoDictionary?["STARCAT_GITHUB_APP_CLIENT_ID"] as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// GitHub App Web Flow 的 Client Secret。
    ///
    /// macOS 原生应用属于 OAuth public client，该值随二进制分发，不能视为真正机密；
    /// 它只用于 user access token 的 code 交换与刷新。权限更大的 GitHub App
    /// private key 仍然禁止进入客户端。
    static var githubAppClientSecret: String {
        let value = Bundle.main.infoDictionary?["STARCAT_GITHUB_APP_CLIENT_SECRET"] as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// “我的项目”GitHub App 的公开 slug，用于构造安装页。
    ///
    /// slug 只负责把用户送到正确的安装页；GitHub 会在安装完成后继续 OAuth 授权，
    /// 并回跳独立的 GitHub App callback。
    static var githubAppSlug: String {
        let value = Bundle.main.infoDictionary?["STARCAT_GITHUB_APP_SLUG"] as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// GitHub App 安装期间 OAuth 回调地址，与主 OAuth 登录 callback 分开路由。
    static let githubAppCallbackURL = "\(oauthCallbackScheme)://github-app/callback"

    /// 精确识别 GitHub App 项目权限 callback，防止主登录 `starcat://callback` 串线。
    static func isGitHubAppCallback(_ url: URL) -> Bool {
        url.scheme == oauthCallbackScheme
            && url.host == "github-app"
            && url.path == "/callback"
    }

    /// 当前构建是否具备完整 GitHub App Web Flow 配置。
    static var isGitHubAppConfigured: Bool {
        !githubAppClientID.isEmpty
            && !githubAppClientSecret.isEmpty
            && githubAppInstallationURL != nil
    }

    /// 当前 GitHub App 的安装入口。非法或空 slug 返回 nil，禁止拼出可疑外链。
    static var githubAppInstallationURL: URL? {
        makeGitHubAppInstallationURL(slug: githubAppSlug)
    }

    /// 用户管理已安装 GitHub App 与仓库范围的 GitHub 固定入口。
    static let githubAppSettingsURL = URL(string: "https://github.com/settings/installations")!

    /// 由公开 slug 构造安装 URL。
    ///
    /// GitHub App slug 只允许 ASCII 字母、数字和连字符。这里显式收窄字符集，
    /// 避免配置错误把 `/`、查询参数或其它 URL 片段带入外部跳转。
    static func makeGitHubAppInstallationURL(slug: String, state: String? = nil) -> URL? {
        let normalized = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
        )
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy(allowed.contains)
        else {
            return nil
        }
        guard let baseURL = URL(string: "https://github.com/apps/\(normalized)/installations/new")
        else {
            return nil
        }
        guard let state, !state.isEmpty else { return baseURL }
        return baseURL.appending(queryItems: [URLQueryItem(name: "state", value: state)])
    }

    // MARK: - 网络

    // 注：2026-06-08 起 `githubAPIBaseURL` 迁到 `AppEndpoints.GitHubREST.baseURL`，
    // 统一与其它 REST 端点（OAuth / 自建后端）放在同一目录管理。
    // 历史调用方（如 `GitHubAPIClient` 默认参数）都已改用新位置。

    /// 默认 User-Agent，GitHub API 要求必须设置。
    static let httpUserAgent = "Starcat/0.1 (+\(bundleIdentifier))"
}
