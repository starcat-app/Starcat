//
//  StarcatAPIKey.swift
//  Starcat
//
//  Starcat 自建后端（trending / weekly / sharing）的 Bearer Token 解析中心。
//
//  对应文档：`docs/详细设计/18-三场景共用架构.md` v1.2 §6.4（Bearer Auth 注入）
//
//  ────────────────────────────────────────────────────────────────────────────
//  API Key 生效优先级（hybrid 模型）
//  ────────────────────────────────────────────────────────────────────────────
//
//  解析顺序（先命中即返回非空字符串）：
//    1. 用户在「设置 → 服务」Tab 填的 BYOK Key
//       → 持久化在 KeychainManager 加密本地文件（`Starcat/Core/Keychain/KeychainManager.swift`）
//       → AppSettings.customServiceAPIKey(for:) 读取
//    2. xcconfig 注入的 baked-in production 默认 Key
//       → `Configs/Secrets.xcconfig` 里的 `STARCAT_PRODUCTION_API_KEY` 字段
//       → 经 project.yml `info.properties` 写入 `Info.plist`
//       → 本文件 `StarcatAPIKeyDefaults.productionKey` 读 Bundle.main.infoDictionary
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

/// production 后端 fly.io 部署的默认 API Key，从 `Info.plist` 读取（来源是
/// `Configs/Secrets.xcconfig` 的 `STARCAT_PRODUCTION_API_KEY` 字段）。
///
/// **当 `Secrets.xcconfig` 不存在或字段为空时**：
///   - `productionKey` 解析为 `nil`
///   - App 运行期表现为「BYOK-only 模式」：用户必须在「设置 → 服务」Tab 填自己的 Key
///     否则任何 trending / weekly / sharing 请求都会被后端拒 401
///
/// **当 `Secrets.xcconfig` 填了真实 Key 时**：
///   - `productionKey` 解析为该 Key
///   - 用户首次启动可零配置直接用 production 服务（BYOK 仍可在设置页覆盖）
///
/// 替换方式：见 `Configs/Secrets.xcconfig.template` 文件头说明。
enum StarcatAPIKeyDefaults {

    /// `Info.plist` 里 production 默认 Key 的 key 名（与 project.yml `info.properties` 对齐）。
    private static let infoPlistKey = "STARCAT_PRODUCTION_API_KEY"

    /// production 默认 Key（可能为 nil 或空字符串，调用方需进一步判空）。
    ///
    /// 读取 `Bundle.main.infoDictionary[infoPlistKey] as? String`：
    /// - 缺失（key 不在 Info.plist）→ nil
    /// - 空字符串（xcconfig 未填值，Xcode 会保留空字符串）→ ""
    /// - 真实 Key → "sk-starcat-..."
    ///
    /// 调用方应通过 `productionKeyOrNil` 一步走，避免重复判空。
    static var productionKeyOrNil: String? {
        let raw = Bundle.main.infoDictionary?[infoPlistKey] as? String
        guard let raw, !raw.isEmpty else { return nil }
        // 防御性 trim：xcconfig 编辑器易混入末尾空白
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
    /// - Parameter settings: BYOK 来源；默认 `AppSettings.shared`，测试可注入隔离实例。
    ///
    /// `@MainActor` 是因为读 `AppSettings`（`@Observable @MainActor` 类型）。
    @MainActor
    static func resolve(
        for service: ThirdPartyService,
        settings: AppSettings = .shared
    ) -> String? {
        if let custom = settings.customServiceAPIKey(for: service),
           !custom.isEmpty {
            return custom
        }
        return StarcatAPIKeyDefaults.productionKeyOrNil
    }
}
