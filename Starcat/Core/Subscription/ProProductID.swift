//
//  ProProductID.swift
//  Starcat
//
//  StoreKit Product ID 集中定义。
//

import Foundation

/// Starcat Pro 在 App Store Connect / `.storekit` 中使用的商品 ID。
///
/// 约束：
/// - 代码、App Store Connect、`Products.storekit` 必须保持完全一致；
/// - App Store 版同时启用月订、年订和 lifetime 买断；
/// - UI 价格从 StoreKit `Product.displayPrice` 读取，不在代码里写死。
enum ProProductID: String, CaseIterable, Identifiable, Sendable {
    case monthly = "com.starcat.app.pro.monthly"
    case yearly = "com.starcat.app.pro.yearly"
    case lifetime = "com.starcat.app.pro.lifetime"

    var id: String { rawValue }

    static let allIDs: [String] = Self.allCases.map(\.rawValue)

    var sortOrder: Int {
        switch self {
        case .monthly: return 0
        case .yearly: return 1
        case .lifetime: return 2
        }
    }

    static func sortOrder(for productID: String) -> Int {
        Self(rawValue: productID)?.sortOrder ?? Int.max
    }
}
