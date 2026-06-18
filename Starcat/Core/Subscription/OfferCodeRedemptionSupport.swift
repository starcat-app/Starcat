//
//  OfferCodeRedemptionSupport.swift
//  Starcat
//
//  App Store Offer Code 兑换：SwiftUI 系统 sheet（macOS 15+）。
//
//  macOS 原生 App 应使用 `View.offerCodeRedemption`，而不是
//  `AppStore.presentOfferCodeRedeemSheet(in: UIWindowScene)`（该 API 面向 iOS）。
//

import StoreKit
import SwiftUI

/// 挂载 Apple Offer Code 兑换 sheet，并在成功后回调。
private struct OfferCodeRedemptionModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(SubscriptionManager.self) private var subscriptionManager
    var onActivated: () -> Void

    func body(content: Content) -> some View {
        content.offerCodeRedemption(isPresented: $isPresented) { result in
            Task {
                let activated = await subscriptionManager.handleOfferCodeRedemptionResult(result)
                if activated {
                    onActivated()
                }
            }
        }
    }
}

extension View {
    /// 为当前视图挂载 Offer Code 兑换 sheet。
    func starcatOfferCodeRedemption(
        isPresented: Binding<Bool>,
        onActivated: @escaping () -> Void = {}
    ) -> some View {
        modifier(OfferCodeRedemptionModifier(isPresented: isPresented, onActivated: onActivated))
    }
}
