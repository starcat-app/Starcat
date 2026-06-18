//
//  ProEntitlement.swift
//  Starcat
//
//  Pro 权益快照。
//

import Foundation

/// StoreKit 校验后的 Pro 权益快照。
///
/// 为什么不用裸 `Bool`：
/// - 设置页需要展示来源、过期时间、最近刷新时间；
/// - 门控只关心 `isActive`，但调试订阅问题时需要知道是哪一个 product 生效；
/// - 后续如果接 App Store Server API，可以在不改业务门控的情况下扩展 source。
struct ProEntitlement: Equatable, Sendable {
    enum Source: String, Sendable {
        case none
        case storeKit
        case testEnvironment
        case debugOverride
    }

    var isActive: Bool
    var productID: String?
    var expirationDate: Date?
    var verifiedAt: Date?
    var source: Source

    static let inactive = ProEntitlement(
        isActive: false,
        productID: nil,
        expirationDate: nil,
        verifiedAt: nil,
        source: .none
    )

    static let testEnvironment = ProEntitlement(
        isActive: true,
        productID: "test.starcat.pro",
        expirationDate: nil,
        verifiedAt: Date(),
        source: .testEnvironment
    )
}

/// 轻量权益提供者协议，让门控和测试不需要直接依赖 StoreKit 类型。
@MainActor
protocol ProEntitlementProviding: AnyObject {
    var entitlement: ProEntitlement { get }
}
