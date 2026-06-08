//
//  AppEndpoints.swift
//  Starcat
//
//  Starcat 所有 REST API 端点的集中目录（baseURL + path）。
//
//  本文件是 Starcat 网络请求的「单一信任源」。任何 REST 端点都应该在这里以
//  `BaseURL + Paths.xxx` 形式登记，**禁止**在调用方文件里硬编码 path 字符串。
//
//  组织结构：每个后端服务一个嵌套 enum 命名空间（Weekly / Trending / Sharing /
//  GitHubREST / GitHubOAuth），命名空间内含三件套：
//    - `baseURL`        ：服务的 base URL；自建后端走 AppSettings 可热更新，固定端走 let。
//    - `Paths`           ：path 常量目录（扁平命名，工厂方法处理 path 参数）。
//    - `url(_:) -> URL`  ：把 Paths.xxx 拼到 baseURL 上，返回完整 URL。
//
//  历史演进：
//  - v1（2026-06-08 18:50）：仅 weekly/trending/sharing 三个 baseURL 集中 + `#if DEBUG` env 覆盖。
//  - v2（2026-06-08 20:00）：env 系统删除，自建后端 baseURL 改走设置页 → 服务 Tab。
//  - v3（2026-06-08 21:00 当前）：把所有 REST path 全部集中到本文件——GitHub REST 7 个 path、
//    OAuth 3 个 path、自建后端 3 个 path——按服务命名空间整理。调用方写 `path: AppEndpoints
//    .GitHubREST.Paths.userStarred`，grep 标识符就能定位所有引用点。
//
//  非 REST 链接（GitHub 网页跳转、第三方装饰链接）**不**放本文件：
//    - GitHub 网页跳转（github.com/{login}, github.com/{owner}/{repo} 等）→ `GitHubURLs.swift`
//    - 第三方装饰链接（starcat.app、致谢列表）→ 各 View 就近常量
//    - AI 提供商端点 → `AIServiceProvider.defaultBaseURL`（已是单一信任源）
//
//  设计约束：
//  - 自建后端的 `baseURL` getter 标 `@MainActor`（要读 `AppSettings.shared`），导致 actor init
//    无法用它作 default 参数；三个 API 的 `init(baseURL:)` 都没有默认值，强制 DI/测试显式传。
//  - `Sharing.healthzURL` 是单独 helper，不在 `Sharing.Paths` 里。因为 sharing 的 baseURL 含
//    `/api` 后缀（业务请求用），而 `/healthz` 挂在根路径，路径拼接语义不一样；放 Paths 里
//    会让用户写 `Sharing.url(Sharing.Paths.healthz)` 拼出 `.../api/healthz`（错的）。
//  - `Paths.xxx` 全部以 `/` 开头，便于源码 grep 时直观；`url(_:)` 内部做 trim。
//

import Foundation
import os
import SwiftUI

/// Starcat 所有 REST API 端点的集中目录。
///
/// 不可实例化，仅暴露嵌套命名空间。
enum AppEndpoints {

    // MARK: - 自建后端 1/3：Weekly（阮一峰周刊推荐 GitHub 项目）

    /// 阮一峰周刊后端 endpoint 集合。
    enum Weekly {
        /// 生产环境默认 URL（fly.io）。
        static let productionURL = URL(string: "https://starcat-weekly-api.fly.dev")!

        /// 当前生效的 baseURL（用户设置页可改）。先查 `AppSettings.customServiceURL(for: .weekly)`，
        /// 无则回退到 `productionURL`。@MainActor 是因为读 AppSettings.shared。
        @MainActor
        static var baseURL: URL {
            AppEndpoints.resolve(production: productionURL, service: .weekly)
        }

        /// Path 常量目录。新增端点时在此追加。
        enum Paths {
            /// `GET /api/weekly/projects?page=&page_size=` —— 分页拉项目列表。
            static let projects = "/api/weekly/projects"
            /// `GET /healthz` —— 健康检查（与业务 path 同级，无需特殊处理）。
            static let healthz = "/healthz"
        }

        /// 把 `Paths.xxx` 拼到当前 baseURL 上。
        /// path 首尾的 `/` 由 `appendingPathComponent` 容错处理，常量定义里保留 `/` 前缀方便阅读。
        @MainActor
        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
        }
    }

    // MARK: - 自建后端 2/3：Trending（GitHub Trending 抓取）

    /// GitHub Trending 后端 endpoint 集合。
    enum Trending {
        static let productionURL = URL(string: "https://starcat-trending-api.fly.dev")!

        @MainActor
        static var baseURL: URL {
            AppEndpoints.resolve(production: productionURL, service: .trending)
        }

        enum Paths {
            /// `GET /repo?lang=&since=daily/weekly/monthly` —— Trending 仓库列表。
            static let repos = "/repo"
            /// `GET /user?lang=&since=&sponsorable=1` —— Trending 开发者列表（P1+ 预留）。
            static let users = "/user"
            /// `GET /lang` —— 支持的语言字典（启动时缓存）。
            static let languages = "/lang"
            /// `GET /healthz` —— 健康检查。
            static let healthz = "/healthz"
        }

        @MainActor
        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
        }
    }

    // MARK: - 自建后端 3/3：Sharing（AI 分享卡）

    /// AI 分享卡后端 endpoint 集合。
    ///
    /// **特殊语义**：`baseURL` 含 `/api` 后缀（与生产部署语义一致，业务请求都在 `/api/*` 下）；
    /// `/healthz` 挂在根路径（即 `baseURL` 的父级），所以提供独立的 `healthzURL` getter
    /// 而非把 healthz 放进 `Paths` —— 避免有人写 `Sharing.url(Paths.healthz)` 拼出错的 URL。
    enum Sharing {
        /// 生产 URL（含 `/api` 后缀）。
        static let productionURL = URL(string: "https://starcat-sharing-api.fly.dev/api")!

        @MainActor
        static var baseURL: URL {
            AppEndpoints.resolve(production: productionURL, service: .sharing)
        }

        enum Paths {
            /// `POST /share` —— 相对 `baseURL`，即 `<base>/api/share`。
            static let share = "/share"
            // 注意：故意不放 healthz 在 Paths 里。healthz 走根路径，参见 `healthzURL` getter。
        }

        @MainActor
        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
        }

        /// 健康检查 URL。剥掉 `/api` 后缀再拼 `/healthz`，因为 `/healthz` 挂在根路径。
        ///
        /// 调用方一般不直接用本 getter——`ServiceHealthChecker` 走
        /// `ThirdPartyService.healthCheckURL(base:)`，支持传入"草稿 URL"测试连接。
        /// 本 getter 仅用于"用当前生效 baseURL 测试"的简化路径。
        @MainActor
        static var healthzURL: URL {
            Self.healthzURL(over: baseURL)
        }

        /// 给定任意 `base`（可能是草稿、持久化、默认）拼出 healthz URL。
        /// 用 static func 而非 instance method 是为了让"测试连接"路径不依赖 @MainActor 状态。
        static func healthzURL(over base: URL) -> URL {
            let root: URL
            if base.path.hasSuffix("/api") {
                root = base.deletingLastPathComponent()
            } else {
                root = base
            }
            return root.appendingPathComponent("healthz")
        }
    }

    // MARK: - GitHub REST API

    /// GitHub REST API endpoint 集合。baseURL 固定，所有 path 在 `Paths` 集中。
    enum GitHubREST {
        /// REST API root。
        static let baseURL = URL(string: "https://api.github.com")!

        /// Path 常量目录。带占位符的用工厂方法生成。
        enum Paths {
            // —— 用户 ——
            /// `GET /user` —— 当前登录用户。
            static let currentUser = "/user"
            /// `GET /user/starred` —— 当前用户的 starred 列表。
            static let userStarred = "/user/starred"
            /// `PUT/DELETE /user/starred/{owner}/{repo}` —— star / unstar 单仓库。
            static func starRepo(owner: String, repo: String) -> String {
                "/user/starred/\(owner)/\(repo)"
            }

            // —— 仓库 ——
            /// `GET /repos/{owner}/{repo}/readme` —— README 内容。
            static func repoReadme(owner: String, repo: String) -> String {
                "/repos/\(owner)/\(repo)/readme"
            }
            /// `GET /repos/{owner}/{repo}/releases` —— release 列表。
            static func repoReleases(owner: String, repo: String) -> String {
                "/repos/\(owner)/\(repo)/releases"
            }
            /// `GET/PUT/DELETE /repos/{owner}/{repo}/subscription` —— release 订阅。
            static func repoSubscription(owner: String, repo: String) -> String {
                "/repos/\(owner)/\(repo)/subscription"
            }

            // —— GraphQL ——
            /// `POST /graphql` —— GraphQL 入口（与 REST 同一 baseURL）。
            static let graphql = "/graphql"
        }

        /// 把 `Paths.xxx` 拼到 baseURL 上。
        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
        }
    }

    // MARK: - GitHub OAuth（Device Flow）

    /// GitHub OAuth Device Flow endpoint 集合。
    /// baseURL 是 `github.com`（不是 `api.github.com`）；OAuth 路径走主域名。
    enum GitHubOAuth {
        static let baseURL = URL(string: "https://github.com")!

        enum Paths {
            /// `POST /login/device/code` —— 申请 device code。
            static let deviceCode = "/login/device/code"
            /// `POST /login/oauth/access_token` —— 用 device code 换 access token。
            static let accessToken = "/login/oauth/access_token"
            /// `https://github.com/login/device` —— 用户在浏览器里输入 user_code 的页面（verification URI）。
            static let deviceVerification = "/login/device"
        }

        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
        }
    }

    // MARK: - 公共辅助

    /// `ThirdPartyService` → 生效 baseURL 的 dispatch。
    /// 给 `ThirdPartyService.productionURL` / `ServicesSettingsView`(captionRow 显示"当前生效") 用。
    @MainActor
    static func resolved(for service: ThirdPartyService) -> URL {
        switch service {
        case .weekly:   return Weekly.baseURL
        case .trending: return Trending.baseURL
        case .sharing:  return Sharing.baseURL
        }
    }

    /// `ThirdPartyService` → 生产默认 URL 的 dispatch。
    /// 给 `ThirdPartyService.productionURL` / 重置按钮 / TextField placeholder 用。
    static func production(for service: ThirdPartyService) -> URL {
        switch service {
        case .weekly:   return Weekly.productionURL
        case .trending: return Trending.productionURL
        case .sharing:  return Sharing.productionURL
        }
    }

    /// 在启动期调一次，把所有自建后端 baseURL 解析后的值写到 OSLog。
    /// 不在 getter 内部记日志（会被反复调用）；统一在 `AppDependencies.init` 调一次。
    @MainActor
    static func logResolvedEndpoints() {
        AppLog.network.info("endpoint.weekly   = \(Weekly.baseURL.absoluteString, privacy: .public)")
        AppLog.network.info("endpoint.trending = \(Trending.baseURL.absoluteString, privacy: .public)")
        AppLog.network.info("endpoint.sharing  = \(Sharing.baseURL.absoluteString, privacy: .public)")
    }

    // MARK: - Private

    /// 自建后端 baseURL 解析：用户设置过 → 用之；否则回退 production。
    ///
    /// 写入路径（`AppSettings.setCustomURL`）已经在写前校验，万一历史数据脏了（URL.init 失败 /
    /// scheme 缺失），本函数安全降级到 production。
    @MainActor
    private static func resolve(production: URL, service: ThirdPartyService) -> URL {
        if let raw = AppSettings.shared.customServiceURL(for: service),
           !raw.isEmpty,
           let url = URL(string: raw),
           url.scheme != nil {
            return url
        }
        return production
    }

    /// 把 path 拼到 base 上的标准实现。
    /// 容错处理 path 的 `/` 前缀（Paths 常量都带 `/` 开头便于阅读，但 `appendingPathComponent`
    /// 在 base 已有 path 时遇到带 `/` 前缀的 component 容易拼出 `//` 双斜杠），统一 trim。
    ///
    /// **何时用 `Namespace.url(_:)` vs `AppEndpoints.appendPath(_:to:)`**：
    /// - `Namespace.url(_:)` —— 每次都读 `AppSettings.shared.customServiceURL` 取最新 baseURL；
    ///   适合 UI 侧"现在拼一个 URL 直接 open / Link"的一次性场景。
    /// - `AppEndpoints.appendPath(_:to:)` —— 用调用方传入的 `base`；适合 actor 内部，因为 actor
    ///   持有自己的 baseURL 副本（通过 `updateBaseURL` 热更新），不应该绕开本地状态再去读
    ///   AppSettings（concurrency 隔离 + 单一来源原则）。
    static func appendPath(_ path: String, to base: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return base }
        return base.appendingPathComponent(trimmed)
    }
}
