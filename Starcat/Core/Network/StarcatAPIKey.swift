//
//  StarcatAPIKey.swift
//  Starcat
//
//  Starcat 自建后端（trending / weekly / sharing）的 Bearer Token 解析中心。
//
//  对应文档：`docs/详细设计/18-三场景共用架构.md` v1.2 §6.4（Bearer Auth 注入）
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️ Production 默认 Key 设计取舍（dong4j 2026-06-09 拍板待定）
//  ────────────────────────────────────────────────────────────────────────────
//  后端三个 API（trending/weekly/sharing）改造后强制 `API_KEYS` env，前端必须发
//  `Authorization: Bearer <key>` 否则 401。前端目前有三种方案在权衡：
//
//  方案 A（baked-in）：编译期把 production key 写在 xcconfig / Info.plist；
//                     用户零感知；公开 repo 反编译易暴露但后端可做 IP-level rate limit
//  方案 B（BYOK）：    设置页让用户填，写 Keychain；production 不内置任何 key；
//                     首次进 trending/weekly tab 引导用户去填
//  方案 C（hybrid）：   baked-in production 默认 + 设置页可覆盖（自建后端时填自己的 key）
//
//  当前 P1a 阶段实现：
//   - 实现 C 的"骨架"：本文件提供 production 默认 key 占位常量
//   - 用户在设置页可覆盖（走 AppSettings.customServiceAPIKey(for:)）
//   - **占位常量目前是 placeholder 字符串**，等 dong4j 拍板后只需修改 `productionDefault`
//     一个常量即可发版
//   - 如果决定走 B 方案：把 `productionDefault` 改回空字符串，让前端在 key 未配置时
//     发请求不带 Authorization 头（后端会 401，UI 上提示「请配置 API Key」）
//  ────────────────────────────────────────────────────────────────────────────
//
//  TODO(P1b)：完整 BYOK UX
//   - KeychainManager 添加 service-keyed API key 存取
//   - AppSettings.customServiceAPIKeys 字段从 UserDefaults 迁到 Keychain
//   - 设置页加 SecureField 字段 + 测试连接含鉴权
//   - 实现 Phase 2 时本文件几乎不变，只换 `StarcatAPIKeyResolver.resolve` 的源
//

import Foundation

// MARK: - Production 默认 API Key

/// production 后端 fly.io 部署的默认 API Key 占位。
///
/// **当前状态**：placeholder 占位字符串，**未投入 production**。
/// dong4j 拍板方案后只需替换 `productionKey` 常量值。
///
/// 替换示例（baked-in 方案）：
/// ```swift
/// static let productionKey = "sk_starcat_prod_2026_xxxx"  // 实际 production key
/// ```
///
/// 替换示例（BYOK-only 方案）：
/// ```swift
/// static let productionKey = ""  // 强制用户在设置页填，否则请求 401
/// ```
enum StarcatAPIKeyDefaults {
    /// 占位 key，**不要在 production 用**——后端会拒绝。
    /// 等用户拍板 baked-in / BYOK 决策后替换。
    static let productionKey = "STARCAT_PROD_KEY_PLACEHOLDER"
}

// MARK: - Resolver

/// 给定一个服务，解析出当前应当使用的 API Key（设置页覆盖优先 → production 默认）。
///
/// 解析顺序（先命中即返回）：
/// 1. `AppSettings.shared.customServiceAPIKey(for: service)` —— 用户在设置页配置过
/// 2. `StarcatAPIKeyDefaults.productionKey` —— production 默认 key（占位，待拍板）
///
/// 返回 `String?`：
/// - 非 nil 且非空 → 调用方应在请求头加 `Authorization: Bearer <returned>`
/// - nil 或空字符串 → 调用方**不发** Authorization 头；后端返回 401 时 UI 提示「请配置 API Key」
enum StarcatAPIKeyResolver {

    /// 解析当前生效的 API Key。
    ///
    /// @MainActor 是因为读 `AppSettings.shared`。
    @MainActor
    static func resolve(for service: ThirdPartyService) -> String? {
        if let custom = AppSettings.shared.customServiceAPIKey(for: service),
           !custom.isEmpty {
            return custom
        }
        let prod = StarcatAPIKeyDefaults.productionKey
        return prod.isEmpty ? nil : prod
    }
}
