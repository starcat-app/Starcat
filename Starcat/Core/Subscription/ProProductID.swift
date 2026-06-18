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
/// - v1 只启用月订 + 年订，lifetime 买断只在文档中预留，不进入本轮代码路径；
/// - UI 价格从 StoreKit `Product.displayPrice` 读取，不在代码里写死。
enum ProProductID: String, CaseIterable, Identifiable, Sendable {
    case monthly = "com.starcat.app.pro.monthly"
    case yearly = "com.starcat.app.pro.yearly"

    var id: String { rawValue }

    static let allIDs: [String] = Self.allCases.map(\.rawValue)

    var sortOrder: Int {
        switch self {
        case .yearly: return 0
        case .monthly: return 1
        }
    }

    static func sortOrder(for productID: String) -> Int {
        Self(rawValue: productID)?.sortOrder ?? Int.max
    }
}
