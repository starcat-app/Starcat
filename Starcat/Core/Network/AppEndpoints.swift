//
//  AppEndpoints.swift
//  Starcat
//
//  Starcat 三个自建后端 API 的端点集中配置。
//
//  解决的问题：
//  - 此前 `WeeklyAPI` / `TrendingAPI` / `ShareAPI` 的 baseURL 直接写死在各自 init
//    默认参数里，本地联调时只能改源码 + 重 build，体验割裂。
//  - 现在把三个端点抽到这一份"单一信任源"，本地开发改 env 即可切到 localhost，
//    生产构建强制走 fly.dev、env 完全失效，避免误把本地地址打进 Release 包。
//
//  使用方式（仅 DEBUG 生效）：
//    1. Xcode → Edit Scheme → Run → Arguments → Environment Variables 勾选下方任一项；
//       这些 env 已通过 `project.yml` 预填，dong4j 只需勾选 / 取消即可切换。
//    2. 也可在命令行 / CI 跑 `xcodebuild` 时通过 `-launch-args` 注入。
//    3. 三个 env 互相独立，可以只切一个（例如本地只开 weekly，sharing/trending 仍走生产）。
//
//  支持的环境变量（DEBUG 编译期）：
//    - STARCAT_WEEKLY_API_URL   覆盖 weekly  端点，未设置时回退本地默认 http://127.0.0.1:5003
//    - STARCAT_TRENDING_API_URL 覆盖 trending 端点，未设置时回退本地默认 http://127.0.0.1:5002
//    - STARCAT_SHARING_API_URL  覆盖 sharing  端点，未设置时回退本地默认 http://127.0.0.1:5001/api
//
//  额外开关（DEBUG 编译期）：
//    - STARCAT_USE_PRODUCTION_API = "1" / "true" / "yes" 时，DEBUG 也强制走 fly.dev 生产端点，
//      env 单条覆盖仍然生效（你只想看一两个走本地、其余走生产时）。默认未设 = DEBUG 走本地。
//      ↑ 这条对 dong4j 的常用场景特别有用：默认 DEBUG 本地，临时想验证生产数据就 export 一下。
//
//  关键约束：
//  - `#if DEBUG` 把 env 读取分支完全编译掉，Release 二进制里只剩生产 URL 字面量，
//    从机器码层面断绝"用户在生产版改 env 把流量打到本地伪服务"的可能。
//  - macOS ATS 默认对 `127.0.0.1` / `localhost` 放行（不属于 arbitrary loads），所以走
//    http://127.0.0.1:<port> 不需要在 Info.plist 加 NSAllowsLocalNetworking。
//  - sharing 端点保留 `/api` 后缀，与 `ShareAPI` 内部 `appendingPathComponent("share")`
//    拼出 `/api/share` 的约定一致；不要在外部去掉这个后缀。
//  - 启动期通过 `AppLog.network.info` 打印解析后的三个 URL（DEBUG 才打 `[DEV]` 标记），
//    方便确认"我现在到底打的是本地还是生产"。
//

import Foundation
import os

/// Starcat 自建后端 API 端点集中配置。
///
/// 不可实例化，仅暴露静态 getter。命名与 `AppConstants` 一致以表达"全局只读常量"语义。
enum AppEndpoints {

    // MARK: - 生产端点（Release 强制 / DEBUG 当兜底）

    /// 阮一峰周刊后端（GET /api/weekly/projects）。
    static let weeklyProduction = URL(string: "https://starcat-weekly-api.fly.dev")!

    /// GitHub Trending 抓取后端（GET /repo）。
    static let trendingProduction = URL(string: "https://starcat-trending-api.fly.dev")!

    /// AI 分享卡后端（POST /api/share）。
    /// 注意保留 `/api` 后缀——`ShareAPI` 内部按 `appendingPathComponent("share")` 拼，
    /// 拿掉就会变成 `/share` 调不通。
    static let sharingProduction = URL(string: "https://starcat-sharing-api.fly.dev/api")!

    // MARK: - 本地开发端点（约定端口与 supports/ 下三个服务对齐）
    //
    // 这三个常量"声明"上不加 `#if DEBUG`：只是 3 个 URL 字面量，在 Release 二进制里
    // 多带几十字节也无所谓；真正的开关在 `resolved(...)` 里——Release 编译时连读取
    // 它们的分支都被剥离掉，所以**实际运行时不会被使用**。
    //
    // 这样做的好处：getter 的闭包 `{ weeklyLocalDefault }` 在 Release 也能编译过，
    // 不用为每个 getter 写两套 `#if DEBUG/#else` 分支。

    /// 本地 weekly 默认（dong4j 2026-06-08 约定端口）。
    static let weeklyLocalDefault = URL(string: "http://127.0.0.1:5003")!
    /// 本地 trending 默认。
    static let trendingLocalDefault = URL(string: "http://127.0.0.1:5002")!
    /// 本地 sharing 默认（含 `/api` 后缀，与生产保持一致）。
    static let sharingLocalDefault = URL(string: "http://127.0.0.1:5001/api")!

    // MARK: - 对外解析后的端点（三个 API 客户端的 init 默认参数读这里）

    /// Weekly API 当前生效的 baseURL。
    static var weekly: URL {
        resolved(
            production: weeklyProduction,
            localDefault: { weeklyLocalDefault },
            envKey: "STARCAT_WEEKLY_API_URL"
        )
    }

    /// Trending API 当前生效的 baseURL。
    static var trending: URL {
        resolved(
            production: trendingProduction,
            localDefault: { trendingLocalDefault },
            envKey: "STARCAT_TRENDING_API_URL"
        )
    }

    /// Sharing API 当前生效的 baseURL。
    static var sharing: URL {
        resolved(
            production: sharingProduction,
            localDefault: { sharingLocalDefault },
            envKey: "STARCAT_SHARING_API_URL"
        )
    }

    // MARK: - 启动期诊断

    /// 在启动期调一次，把三个 baseURL 实际解析值写到 OSLog，方便确认"我现在跑的是本地还是生产"。
    ///
    /// 不在 `resolved` 内部记日志的理由：getter 可能被多处反复调用（每次 `WeeklyAPI()` 都会读），
    /// 重复日志噪声大；统一在 `AppDependencies.init` 调一次即可。
    static func logResolvedEndpoints() {
        #if DEBUG
        let tag = "[DEV]"
        #else
        let tag = ""
        #endif
        AppLog.network.info("\(tag, privacy: .public) endpoint.weekly   = \(weekly.absoluteString, privacy: .public)")
        AppLog.network.info("\(tag, privacy: .public) endpoint.trending = \(trending.absoluteString, privacy: .public)")
        AppLog.network.info("\(tag, privacy: .public) endpoint.sharing  = \(sharing.absoluteString, privacy: .public)")
    }

    // MARK: - Private

    /// 单端点解析规则：
    /// - Release：恒返回 `production`，env 完全不参与（编译期已剥离 env 分支）。
    /// - DEBUG：
    ///   1. 若设置 `STARCAT_USE_PRODUCTION_API`（"1"/"true"/"yes"）→ 默认走 production，
    ///      但 env 单条覆盖（如 `STARCAT_WEEKLY_API_URL`）仍优先生效；
    ///   2. 否则默认走本地 `localDefault`，env 仍可覆盖为任意 URL（包括 0.0.0.0、Cloudflare Tunnel 等）。
    ///
    /// `localDefault` 用 `@autoclosure` 一类的 lazy 调用（这里直接传闭包是因为
    /// `weeklyLocalDefault` 等常量只在 DEBUG 编译期存在；Release 时不能在签名里出现它们）。
    private static func resolved(
        production: URL,
        localDefault: () -> URL,
        envKey: String
    ) -> URL {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment

        if let raw = env[envKey]?.trimmingCharacters(in: .whitespaces),
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }

        if let flag = env["STARCAT_USE_PRODUCTION_API"]?.lowercased(),
           ["1", "true", "yes"].contains(flag) {
            return production
        }

        return localDefault()
        #else
        _ = localDefault
        _ = envKey
        return production
        #endif
    }
}
