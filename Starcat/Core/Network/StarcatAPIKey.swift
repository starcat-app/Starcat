//
//  StarcatAPIKey.swift
//  Starcat
//
//  Starcat 自建后端（trending / weekly / sharing / wiki）的 Bearer Token 解析中心。
//
//  对应文档：`docs/3-设计/详细设计/18-三场景共用架构.md` v1.2 §6.4（Bearer Auth 注入）
//
//  ────────────────────────────────────────────────────────────────────────────
//  API Key 生效优先级（hybrid 模型）
//  ────────────────────────────────────────────────────────────────────────────
//
//  解析顺序（先命中即返回非空字符串）：
//    1. 用户在「设置 → 服务」Tab 填的 BYOK Key
//       → 持久化在 KeychainManager 加密本地文件（`Starcat/Core/Keychain/KeychainManager.swift`）
//       → AppSettings.customServiceAPIKey(for:) 读取
//    2. xcconfig 注入的 baked-in production 默认 Key（**每服务独立**）
//       → `Configs/Secrets.xcconfig` 的 `STARCAT_PRODUCTION_API_KEY_<SERVICE>`
//       → 经 project.yml `info.properties` 写入 `Info.plist`
//       → `StarcatAPIKeyDefaults.productionKeyOrNil(for:)` 读 Bundle.main.infoDictionary
//    3. 都没填 → nil（API actor 不会注入 `Authorization: Bearer` 头，后端必返 401，
//       UI 应在收到 401 时引导用户去设置页填 Key）
//
//  设计取舍（dong4j 2026-06-10 拍板）：
//   - **不**走纯 BYOK：默认要让用户开箱即用 production 服务，否则下载完点开 trending tab
//     就被 401 错误页拍脸劝退
//   - **不**走纯 baked-in：本仓 public 后真实 Key 反编译可见，必须给用户「换成自己 Key」的逃生口
//   - **走 hybrid**：xcconfig 注入 baked-in（不进 git，dong4j 本地填）+ 设置页 BYOK（覆盖默认）
//
//  与 README 配套阅读：
//   - 配置首次发版：`Configs/Secrets.xcconfig.template` 顶部注释
//   - BYOK UI：`Starcat/Features/Settings/ServicesSettingsView.swift`
//   - 持久化迁移：`Starcat/Core/Settings/AppSettings.swift` `setCustomAPIKey(_:for:)`
//  ────────────────────────────────────────────────────────────────────────────
//

import Foundation

// MARK: - Production 默认 API Key（编译期 baked-in）

/// production 后端 fly.io 部署的默认 API Key（按服务从 `Info.plist` 读取）。
///
/// 每个自建服务各自一条 xcconfig / plist 字段，允许 Fly 上 `API_KEYS` 白名单互不相同。
/// 自动化写入：`make setup-production-api-keys`（读 supports/*/ .env）。
enum StarcatAPIKeyDefaults {

    /// 读取指定服务的 production 默认 Key；缺失或空 → nil。
    static func productionKeyOrNil(for service: ThirdPartyService) -> String? {
        let raw = Bundle.main.infoDictionary?[service.productionAPIKeyInfoPlistKey] as? String
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Resolver

/// 给定一个服务，解析出当前应当使用的 API Key（设置页 BYOK 覆盖优先 → production 默认）。
///
/// 解析顺序见文件头「API Key 生效优先级」段。
///
/// 返回 `String?`：
/// - 非 nil 且非空 → 调用方应在请求头加 `Authorization: Bearer <returned>`
/// - nil → 调用方**不发** Authorization 头；后端返回 401 时 UI 提示「请配置 API Key」
enum StarcatAPIKeyResolver {

    /// 解析当前生效的 API Key。
    ///
    /// - Parameter service: 目标服务（trending / weekly / sharing）。
    /// - Parameter settings: BYOK 来源；默认 nil 时函数内部走 `AppSettings.shared`。
    ///   测试可注入隔离实例（同时避免 `AppSettings.shared` 是 `@MainActor` 隔离属性
    ///   被作为 default expression 引用产生的 Swift 6 跨 actor 引用警告）。
    ///
    /// `@MainActor` 是因为读 `AppSettings`（`@Observable @MainActor` 类型）。
    @MainActor
    static func resolve(
        for service: ThirdPartyService,
        settings: AppSettings? = nil
    ) -> String? {
        // 默认参数不能直接是 .shared（Swift 6 报错：main actor-isolated property 不能在
        // nonisolated default expression 求值上下文里访问）。改用 nil 占位，进入函数内
        // @MainActor 上下文后再解析。
        let resolvedSettings = settings ?? AppSettings.shared
        if let custom = resolvedSettings.customServiceAPIKey(for: service),
           !custom.isEmpty {
            return custom
        }
        return StarcatAPIKeyDefaults.productionKeyOrNil(for: service)
    }
}
