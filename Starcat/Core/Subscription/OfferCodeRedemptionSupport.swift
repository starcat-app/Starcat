//
//  OfferCodeRedemptionSupport.swift
//  Starcat
//
//  App Store Offer Code 兑换：挂到入口所属窗口的 StoreKit 系统 sheet。
//
//  设置页与付费墙可能位于不同窗口 / sheet，不能通过 NSApp.keyWindow 猜承载窗口。
//  macOS 27 的新接口直接返回兑换交易；旧系统仍使用其支持的系统控制器接口。
//

import AppKit
import StoreKit
import SwiftUI

/// 挂载 Apple Offer Code 兑换 sheet，并在成功后回调。
private struct OfferCodeRedemptionModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(SubscriptionManager.self) private var subscriptionManager
    var onActivated: () -> Void

    func body(content: Content) -> some View {
        content.background {
            OfferCodeRedemptionPresenter(isPresented: $isPresented) { result in
                let activated = await subscriptionManager.handleOfferCodeRedemptionResult(result)
                if activated {
                    onActivated()
                }
            }
            .frame(width: 0, height: 0)
        }
    }
}

/// 用嵌入当前视图树的控制器定位窗口，避免付费墙中的系统面板挂到主窗口后方。
private struct OfferCodeRedemptionPresenter: NSViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onCompletion: @MainActor (Result<VerificationResult<StoreKit.Transaction>?, Error>) async -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {
        let coordinator = context.coordinator
        guard isPresented, !coordinator.isPresenting else { return }
        coordinator.isPresenting = true

        // 在 SwiftUI 更新结束后展示面板；期间的权益刷新会重算视图，Coordinator 防止重复展示。
        Task { @MainActor in
            defer {
                isPresented = false
                coordinator.isPresenting = false
            }

            let result: Result<VerificationResult<StoreKit.Transaction>?, Error>
            do {
                if #available(macOS 27.0, *) {
                    guard let window = controller.view.window else {
                        throw PresentationError.missingWindow
                    }
                    let verification = try await AppStore.presentOfferCodeRedeemSheet(from: window)
                    result = .success(verification)
                } else {
                    try await AppStore.presentOfferCodeRedeemSheet(from: controller)
                    // 旧系统不返回交易，由 SubscriptionManager 重新读取当前有效权益。
                    result = .success(nil)
                }
            } catch {
                result = .failure(error)
            }
            await onCompletion(result)
        }
    }

    /// 只保存面板的展示状态，避免 SwiftUI 更新过程中回写状态触发重复系统调用。
    final class Coordinator {
        var isPresenting = false
    }

    private enum PresentationError: Error {
        case missingWindow
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
