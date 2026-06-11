//
//  AppEndpoints.swift
//  Starcat
//
//  Starcat 所有 REST API 端点的集中目录（baseURL + path）。
//
//  本文件是 Starcat 网络请求的「单一信任源」。任何 REST 端点都应该在这里以
//  `BaseURL + Paths.xxx` 形式登记，**禁止**在调用方文件里硬编码 path 字符串。
//
//  组织结构：每个后端服务一个嵌套 enum 命名空间（Weekly / Trending / Sharing / Wiki /
//  GitHubREST / GitHubOAuth），命名空间内含三件套：
//    - `baseURL`        ：服务的 base URL；自建后端走 AppSettings 可热更新，固定端走 let。
//    - `Paths`           ：path 常量目录（扁平命名，工厂方法处理 path 参数）。
//    - `url(_:) -> URL`  ：把 Paths.xxx 拼到 baseURL 上，返回完整 URL。
//
//  历史演进：
//  - v1（2026-06-08 18:50）：仅 weekly/trending/sharing 三个 baseURL 集中 + `#if DEBUG` env 覆盖。
//  - v2（2026-06-08 20:00）：env 系统删除，自建后端 baseURL 改走设置页 → 服务 Tab。
//  - v3（2026-06-08 21:00）：把所有 REST path 全部集中到本文件——GitHub REST 7 个 path、
//    OAuth 3 个 path、自建后端 3 个 path——按服务命名空间整理。调用方写 `path: AppEndpoints
//    .GitHubREST.Paths.userStarred`，grep 标识符就能定位所有引用点。
//  - v4（2026-06-11 当前）：新增 Wiki 自建后端，统一接入 URL 设置、健康检查与业务路径。
//  - v5（2026-06-11 R-03.1）：**Sharing 不再特殊**。原来 `Sharing.productionURL` 含 `/api`
//    后缀、Paths 写 `/v1/...` 的设计假设「baseURL 总有 `/api`」，本地自部署填 `:5001` 时
//    业务全 404（路径会少一段 `/api`）。现在统一与其它 3 个服务对齐：productionURL 不含
//    `/api`，Paths 写绝对 `/api/v1/...`。历史用户已存的 `*/api` 后缀 baseURL 由
//    `ThirdPartyService.normalizedBaseURL(_:)` 在保存阶段自动剥除，向后兼容。
//
//  非 REST 链接（GitHub 网页跳转、第三方装饰链接）**不**放本文件：
//    - GitHub 网页跳转（github.com/{login}, github.com/{owner}/{repo} 等）→ `GitHubURLs.swift`
//    - 第三方装饰链接（starcat.app、致谢列表）→ 各 View 就近常量
//    - AI 提供商端点 → `AIServiceProvider.defaultBaseURL`（已是单一信任源）
//
//  设计约束：
//  - 自建后端的 `baseURL` getter 标 `@MainActor`（要读 `AppSettings.shared`），导致 actor init
//    无法用它作 default 参数；四个 API 的 `init(baseURL:)` 都没有默认值，强制 DI/测试显式传。
//  - 客户端「测试连接」走 `/api/v1/ping`，后端为此专门 expose 的 endpoint（R-03 2026-06-11），
//    由 BearerAuth 保护。避免借用业务 endpoint 作 auth probe 的副作用（sharing 的 GET /share
//    返 405、wiki 的 GET /wikis 缺参数返 400 等需要客户端特判的尴尬场景）。
//    详见 ServiceHealthChecker.swift。
//  - `Paths.xxx` 全部以 `/` 开头，便于源码 grep 时直观；`url(_:)` 内部做 trim。
//

import Foundation
import os
import SwiftUI

/// Starcat 所有 REST API 端点的集中目录。
///
/// 不可实例化，仅暴露嵌套命名空间。
enum AppEndpoints {

    // MARK: - 自建后端 1/4：Weekly（阮一峰周刊推荐 GitHub 项目）

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
        ///
        /// R-01 v1.2（2026-06-09）：旧的 `/api/weekly/*` 已统一迁到 `/api/v1/*`
        /// （后端要求 Bearer Auth，详见 supports/starcat-weekly-api/cmd/server/main.go）。
        ///
        /// weekly-api v0.5.2（2026-06-11）：阮一峰周刊端点命名空间从通用 `projects` 改为 weekly 命名
        /// （与 `/api/v1/zread` 风格对齐），`/api/v1/projects` → `/api/v1/weekly`。
        /// 这是 **breaking change** —— 客户端必须同步升级，旧路径已 404。
        enum Paths {
            /// `GET /api/v1/weekly?page=&page_size=&issue=&lang=&sort=` —— 分页拉项目列表（envelope 包装）。
            /// 命名与后端对齐（v0.5.2 起，从 `projects` 改名为 `weekly`）。
            static let projects = "/api/v1/weekly"
            /// `GET /api/v1/weekly/{owner}/{repo}` —— 单 repo 聚合详情（用于 BackendAggregateRepoSource）。
            /// 不是常量，调用方拼字符串：`projectsByOwnerRepo + "/owner/repo"`。
            static let projectsByOwnerRepo = "/api/v1/weekly"
            /// `GET /api/v1/issues` —— 周刊期号列表。
            static let issues = "/api/v1/issues"
            /// `GET /api/v1/ping` —— Starcat 客户端「测试连接」专用端点（R-03 2026-06-11）。
            /// 需要 Bearer Auth，鉴权通过返回 200。详见 supports/starcat-weekly-api/internal/handler/ping.go。
            static let ping = "/api/v1/ping"
        }

        /// 把 `Paths.xxx` 拼到当前 baseURL 上。
        /// path 首尾的 `/` 由 `appendingPathComponent` 容错处理，常量定义里保留 `/` 前缀方便阅读。
        @MainActor
        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
        }
    }

    // MARK: - 自建后端 2/4：Trending（GitHub Trending 抓取）

    /// GitHub Trending 后端 endpoint 集合。
    enum Trending {
        static let productionURL = URL(string: "https://starcat-trending-api.fly.dev")!

        @MainActor
        static var baseURL: URL {
            AppEndpoints.resolve(production: productionURL, service: .trending)
        }

        /// R-01 v1.2（2026-06-09）：旧的 `/repo` `/lang` `/user` 已统一迁到 `/api/v1/*`
        /// （后端要求 Bearer Auth，详见 supports/starcat-trending-api/cmd/server/main.go）。
        enum Paths {
            /// `GET /api/v1/repos?lang=&since=daily/weekly/monthly&limit=` —— Trending 仓库列表（envelope 包装）。
            static let repos = "/api/v1/repos"
            /// `GET /api/v1/users?lang=&since=&sponsorable=1` —— Trending 开发者列表（P1+ 预留）。
            static let users = "/api/v1/users"
            /// `GET /api/v1/languages` —— 支持的语言字典（启动时缓存）。
            static let languages = "/api/v1/languages"
            /// `GET /api/v1/ping` —— Starcat 客户端「测试连接」专用端点（R-03 2026-06-11）。
            /// 需要 Bearer Auth，鉴权通过返回 200。详见 supports/starcat-trending-api/internal/handler/ping.go。
            static let ping = "/api/v1/ping"
        }

        @MainActor
        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
        }
    }

    // MARK: - 自建后端 3/4：Sharing（AI 分享卡）

    /// AI 分享卡后端 endpoint 集合。
    ///
    /// R-03.1（2026-06-11）：与其它 3 个自建后端**完全对齐**——baseURL 是裸 host
    /// （不含 `/api` 后缀），所有 path 写绝对 `/api/v1/...`。
    /// 历史用户如果在 customServiceURL 里存了 `*/api` 形态的 URL，在保存阶段会被
    /// `ThirdPartyService.normalizedBaseURL(_:)` 自动剥除 `/api` 后缀，向后兼容。
    ///
    /// 历史教训：之前 productionURL 设成 `.fly.dev/api`、Paths 写 `/v1/...`，假设
    /// 「baseURL 总会有 `/api`」。本地自部署填 `http://127.0.0.1:5001`（不含 `/api`）
    /// 一进来就 404——不只 ping，业务 share 也是。dong4j 2026-06-11 反馈后修正。
    enum Sharing {
        /// 生产 URL（不含 `/api` 后缀）。
        static let productionURL = URL(string: "https://starcat-sharing-api.fly.dev")!

        @MainActor
        static var baseURL: URL {
            AppEndpoints.resolve(production: productionURL, service: .sharing)
        }

        /// R-01 v1.2（2026-06-09）建立 `/api/v1/*` 命名空间；R-03.1 客户端口径对齐
        /// 后，本目录的 path 与 trending/weekly/wiki 完全同款（绝对路径 `/api/v1/...`）。
        /// 后端路由：详见 supports/starcat-sharing-api/cmd/server/main.go。
        enum Paths {
            /// `POST /api/v1/share` —— 创建分享链接。envelope 包装 + Bearer Auth。
            static let share = "/api/v1/share"
            /// `GET /api/v1/ping` —— Starcat 客户端「测试连接」专用端点（R-03 2026-06-11）。
            /// 需要 Bearer Auth，鉴权通过返回 200。详见 supports/starcat-sharing-api/internal/handler/ping.go。
            static let ping = "/api/v1/ping"
            // 注意：本服务**未列** healthz path。客户端探活已统一收敛到 `ping`（R-03 2026-06-11），
            // 不再调 healthz；后端 healthz 仍在跑（fly.io 健康检查用），但本目录是「Starcat
            // 客户端用到的」端点目录，不调用就不列。
        }

        @MainActor
        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
        }
    }

    // MARK: - 自建后端 4/4：Wiki（外部文档站索引探测）

    /// DeepWiki / Zread / Google Code Wiki 收录状态探测后端。
    enum Wiki {
        static let productionURL = URL(string: "https://starcat-wiki-api.fly.dev")!

        @MainActor
        static var baseURL: URL {
            AppEndpoints.resolve(production: productionURL, service: .wiki)
        }

        enum Paths {
            /// `GET /api/v1/wikis?owner=&repo=` —— 单仓库三源探测。
            static let status = "/api/v1/wikis"
            /// `GET /api/v1/ping` —— Starcat 客户端「测试连接」专用端点（R-03 2026-06-11）。
            /// 需要 Bearer Auth，鉴权通过返回 200。详见 supports/starcat-wiki-api/internal/handler/ping.go。
            static let ping = "/api/v1/ping"
        }

        @MainActor
        static func url(_ path: String) -> URL {
            appendPath(path, to: baseURL)
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
            /// `GET /repos/{owner}/{repo}` —— 单仓库完整元数据（含 description / language /
            /// stargazers_count / topics / license / created_at / updated_at / pushed_at 等）。
            /// 用途：Weekly 详情页（2026-06-08）在本地缓存未命中时拉一份完整 repo 数据，
            /// 拼装临时 Repo 让 UI 复用 `RepoMetadataHeaderView` 渲染。
            static func repo(owner: String, repo: String) -> String {
                "/repos/\(owner)/\(repo)"
            }
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
        case .wiki:     return Wiki.baseURL
        }
    }

    /// `ThirdPartyService` → 生产默认 URL 的 dispatch。
    /// 给 `ThirdPartyService.productionURL` / 重置按钮 / TextField placeholder 用。
    static func production(for service: ThirdPartyService) -> URL {
        switch service {
        case .weekly:   return Weekly.productionURL
        case .trending: return Trending.productionURL
        case .sharing:  return Sharing.productionURL
        case .wiki:     return Wiki.productionURL
        }
    }

    /// 在启动期调一次，把所有自建后端 baseURL 解析后的值写到 OSLog。
    /// 不在 getter 内部记日志（会被反复调用）；统一在 `AppDependencies.init` 调一次。
    @MainActor
    static func logResolvedEndpoints() {
        AppLog.network.info("endpoint.weekly   = \(Weekly.baseURL.absoluteString, privacy: .public)")
        AppLog.network.info("endpoint.trending = \(Trending.baseURL.absoluteString, privacy: .public)")
        AppLog.network.info("endpoint.sharing  = \(Sharing.baseURL.absoluteString, privacy: .public)")
        AppLog.network.info("endpoint.wiki     = \(Wiki.baseURL.absoluteString, privacy: .public)")
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
