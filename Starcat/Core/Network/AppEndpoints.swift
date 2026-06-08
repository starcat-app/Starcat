//
//  AppEndpoints.swift
//  Starcat
//
//  Starcat 三个自建后端 API 的端点集中配置。
//
//  历史演进：
//  - v1（2026-06-08 18:50）：`#if DEBUG` env 覆盖 + 本地端口兜底，方便开发期切到 localhost；
//    缺点是协作者不易发现、Settings 里看不到、无法运行时切换。
//  - v2（2026-06-08 当前）：env 系统**整段删除**，统一走 `AppSettings.customServiceURL`
//    + 设置页 → 服务 Tab UI 配置，DEBUG / Release 路径一致；用户自部署后端时
//    在设置页粘贴 URL 即可热生效，无需重启。
//
//  设计约束：
//  - 这一层只负责"端点解析"（缺省 → 用户自定义 → 兜底 production），**不**做任何
//    网络请求 / actor 持久化；URL 写入由 `AppDependencies.setServiceURL(_:for:)`
//    协调（同时写 AppSettings + 推送到对应 API actor 的 `updateBaseURL`）。
//  - `AppSettings.shared` 是单例 + 主线程隔离，这里调用是安全的；测试侧不依赖
//    Settings（直接传 baseURL）。
//

import Foundation
import os

/// Starcat 自建后端 API 端点集中配置。
///
/// 不可实例化，仅暴露静态 getter。命名与 `AppConstants` 一致以表达"全局只读常量"语义。
enum AppEndpoints {

    // MARK: - 生产端点（fly.io 部署，作为缺省值；用户在设置页可覆盖）

    /// 阮一峰周刊后端（GET /api/weekly/projects）。
    static let weeklyProduction = URL(string: "https://starcat-weekly-api.fly.dev")!

    /// GitHub Trending 抓取后端（GET /repo）。
    static let trendingProduction = URL(string: "https://starcat-trending-api.fly.dev")!

    /// AI 分享卡后端（POST /api/share）。
    /// 注意保留 `/api` 后缀——`ShareAPI` 内部按 `appendingPathComponent("share")` 拼，
    /// 拿掉就会变成 `/share` 调不通。
    static let sharingProduction = URL(string: "https://starcat-sharing-api.fly.dev/api")!

    // MARK: - 对外解析后的端点（三个 API 客户端的 init 默认参数 + DI 装配处读这里）

    /// Weekly API 当前生效的 baseURL。
    /// 先查 `AppSettings.customServiceURL(for: .weekly)`，无则回退到 `weeklyProduction`。
    @MainActor
    static var weekly: URL { resolved(for: .weekly, production: weeklyProduction) }

    /// Trending API 当前生效的 baseURL。
    @MainActor
    static var trending: URL { resolved(for: .trending, production: trendingProduction) }

    /// Sharing API 当前生效的 baseURL（含 `/api` 后缀）。
    @MainActor
    static var sharing: URL { resolved(for: .sharing, production: sharingProduction) }

    /// 给定服务的生效 baseURL。`ThirdPartyService` 也会复用这个 getter，省一次 switch。
    @MainActor
    static func resolved(for service: ThirdPartyService) -> URL {
        switch service {
        case .weekly:   return weekly
        case .trending: return trending
        case .sharing:  return sharing
        }
    }

    /// 给定服务的"生产默认值"——重置按钮、UI 占位符等场景使用。
    static func production(for service: ThirdPartyService) -> URL {
        switch service {
        case .weekly:   return weeklyProduction
        case .trending: return trendingProduction
        case .sharing:  return sharingProduction
        }
    }

    // MARK: - 启动期诊断

    /// 在启动期调一次，把三个 baseURL 解析后的值写到 OSLog，方便确认"当前打的是
    /// fly.dev 还是用户自部署的地址"。
    ///
    /// 不在 getter 内部记日志的理由：getter 可能被多处反复调用（每次 `WeeklyAPI()` 都会读），
    /// 重复日志噪声大；统一在 `AppDependencies.init` 调一次即可。
    @MainActor
    static func logResolvedEndpoints() {
        AppLog.network.info("endpoint.weekly   = \(weekly.absoluteString, privacy: .public)")
        AppLog.network.info("endpoint.trending = \(trending.absoluteString, privacy: .public)")
        AppLog.network.info("endpoint.sharing  = \(sharing.absoluteString, privacy: .public)")
    }

    // MARK: - Private

    /// 单服务端点解析：
    /// - `AppSettings.customServiceURL(for:)` 返回的若是合法 URL → 用它
    /// - 否则回退 production
    ///
    /// 这里没做 URL 格式校验——写入路径（`AppSettings.setCustomURL`）已经在写入前
    /// 校验过；万一历史数据脏了，URL.init 失败时这里安全降级到 production。
    @MainActor
    private static func resolved(for service: ThirdPartyService, production: URL) -> URL {
        if let raw = AppSettings.shared.customServiceURL(for: service),
           !raw.isEmpty,
           let url = URL(string: raw),
           url.scheme != nil {
            return url
        }
        return production
    }
}
