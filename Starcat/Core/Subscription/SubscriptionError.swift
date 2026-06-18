//
//  SubscriptionError.swift
//  Starcat
//
//  StoreKit 订阅错误。
//

import Foundation

/// 订阅链路对 UI 暴露的错误。
///
/// StoreKit 原始错误通常包含实现细节或英文系统串；这里收口成少量用户能理解的状态，
/// 具体错误仍记录到日志，避免把 App Store / Sandbox 的内部信息直接打到界面上。
enum SubscriptionError: Error, LocalizedError, Equatable {
    case productsUnavailable
    case unverifiedTransaction
    case purchasePending
    case purchaseCancelled
    case restoreFailed
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .productsUnavailable:
            return String.l10n("subscription.error.productsUnavailable")
        case .unverifiedTransaction:
            return String.l10n("subscription.error.unverifiedTransaction")
        case .purchasePending:
            return String.l10n("subscription.error.purchasePending")
        case .purchaseCancelled:
            return String.l10n("subscription.error.purchaseCancelled")
        case .restoreFailed:
            return String.l10n("subscription.error.restoreFailed")
        case .unknown(let message):
            return String(format: String.l10n("subscription.error.unknownFormat"), message)
        }
    }
}
