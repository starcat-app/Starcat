//
//  ProPaywallSheet.swift
//  Starcat
//
//  统一 Pro 付费墙。
//

import StoreKit
import SwiftUI

/// 付费墙展示上下文。
///
/// 用 `Identifiable` 是为了业务视图可以直接 `.sheet(item:)`，同一入口重复触发时也能
/// 通过新 UUID 重新打开，不依赖外层 Bool 与 feature 两份状态同步。
struct ProPaywallContext: Identifiable, Equatable {
    let id = UUID()
    var feature: ProFeature
    var message: String?

    init(feature: ProFeature, message: String? = nil) {
        self.feature = feature
        self.message = message
    }
}

/// 统一 Pro 付费墙。
///
/// 产品策略：只在用户触发 Pro 能力或免费限额耗尽时出现；基础 stars 管理工作流不主动打扰。
struct ProPaywallSheet: View {
    let context: ProPaywallContext

    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var didActivate: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            benefits
            products
            footerActions
        }
        .padding(22)
        .frame(width: 420)
        .task {
            await subscriptionManager.loadProducts()
            await subscriptionManager.refreshEntitlements()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ProCrownIcon(size: 46)
            VStack(alignment: .leading, spacing: 6) {
                Text("paywall.title")
                    .font(.title3.weight(.semibold))
                Text(context.message ?? String(format: String.l10n("paywall.subtitleFormat"), context.feature.title))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if didActivate {
                    Label("paywall.activated", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                } else if let error = subscriptionManager.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            paywallBenefit("sparkles", "paywall.benefit.ai")
            paywallBenefit("magnifyingglass.circle.fill", "paywall.benefit.search")
            paywallBenefit("bell.badge.fill", "paywall.benefit.release")
            paywallBenefit("number.circle.fill", "paywall.benefit.limits")
        }
    }

    @ViewBuilder
    private var products: some View {
        if subscriptionManager.isLoadingProducts {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("settings.pro.products.loading")
                    .foregroundStyle(.secondary)
            }
        } else if subscriptionManager.products.isEmpty {
            Text("settings.pro.products.empty")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(subscriptionManager.products, id: \.id) { product in
                    Button {
                        Task { await purchase(product) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName)
                                    .font(.callout.weight(.semibold))
                                Text(product.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(product.displayPrice)
                                .font(.callout.weight(.semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(subscriptionManager.isPurchasing)
                }
            }
        }
    }

    private var footerActions: some View {
        HStack {
            Button("paywall.button.restore") {
                Task { await subscriptionManager.restorePurchases() }
            }
            .disabled(subscriptionManager.isRestoring)

            Button("paywall.button.manage") {
                openURL(SubscriptionExternalLinks.manageSubscriptions)
            }

            Spacer()

            Button("paywall.button.close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func paywallBenefit(_ systemImage: String, _ key: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(key)
                .font(.callout)
        }
    }

    private func purchase(_ product: Product) async {
        let activated = await subscriptionManager.purchase(product)
        guard activated else { return }
        didActivate = true
        try? await Task.sleep(for: .seconds(1))
        dismiss()
    }
}
