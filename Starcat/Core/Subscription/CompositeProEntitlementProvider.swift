//
//  CompositeProEntitlementProvider.swift
//  Starcat
//
//  多渠道 Pro 权益聚合。
//

import Foundation

/// 将 StoreKit、Direct License 等多个权益来源合并为业务层唯一 Pro 真相源。
///
/// 为什么需要这一层：
/// - App Store 包只能走 StoreKit；
/// - Direct 包会走 License API，底层支付网关可能是 Creem，也可能后续替换为其他 provider；
/// - `EntitlementGate` 不应该知道这些渠道差异，否则每个 Pro 功能都要写分支。
@MainActor
@Observable
final class CompositeProEntitlementProvider: ProEntitlementProviding {
    private let settings: AppSettings
    private let providers: [any ProEntitlementProviding]

    private(set) var entitlement: ProEntitlement = .inactive {
        didSet {
            settings.updateProEntitlementMirror(isPro: entitlement.isActive)
        }
    }

    init(settings: AppSettings, providers: [any ProEntitlementProviding]) {
        self.settings = settings
        self.providers = providers
        reloadFromSources()
    }

    /// 重新从所有来源计算当前最强权益。
    ///
    /// 选择规则保持保守：只要任一来源 active 就放行；多个 active 时，优先选择过期时间最晚
    /// 的记录。这样 App Store 用户和 Direct 用户不会互相覆盖，未来临时赠送授权也能自然并存。
    func reloadFromSources() {
        entitlement = Self.bestEntitlement(from: providers.map(\.entitlement))
    }

    static func bestEntitlement(from entitlements: [ProEntitlement]) -> ProEntitlement {
        entitlements
            .filter(\.isActive)
            .max { lhs, rhs in
                (lhs.expirationDate ?? .distantFuture) < (rhs.expirationDate ?? .distantFuture)
            } ?? .inactive
    }
}
