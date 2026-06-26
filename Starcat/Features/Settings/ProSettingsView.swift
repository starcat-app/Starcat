//
//  ProSettingsView.swift
//  Starcat
//
//  Starcat Pro 订阅设置页。
//

import ConfettiSwiftUI
import StoreKit
import SwiftUI

/// Pro 订阅设置页。
///
/// 本页只负责展示与触发购买动作；权益真相源在 `SubscriptionManager`，业务门控在
/// `EntitlementGate`。这样 Settings 页重建、购买弹窗关闭或后续接服务端校验时，
/// 都不会让 Pro 状态分裂成多份。
struct ProSettingsTab: View {

    @Environment(AppSettings.self) private var settings
    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(\.openURL) private var openURL

    @State private var confettiTrigger: Int = 0
    @State private var showSuccessMessage: Bool = false
    @State private var isOfferCodeRedemptionPresented = false

    var body: some View {
        Form {
            heroSection
            benefitsSection
            productSection
            actionSection

        }
        .formStyle(.grouped)
        .starcatOfferCodeRedemption(isPresented: $isOfferCodeRedemptionPresented) {
            showSuccessMessage = true
            confettiTrigger += 1
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                showSuccessMessage = false
            }
        }
        .task {
            await subscriptionManager.loadProducts()
            await subscriptionManager.refreshEntitlements()
        }
        .confettiCannon(
            trigger: $confettiTrigger,
            num: 60,
            confettis: [
                .shape(.circle),
                .shape(.triangle),
                .shape(.square),
                .shape(.slimRectangle),
                .text("PRO")
            ],
            colors: [.yellow, .orange, .red, .pink, .purple, .green, .blue],
            confettiSize: 12,
            rainHeight: 520,
            fadesOut: true,
            openingAngle: Angle(degrees: 0),
            closingAngle: Angle(degrees: 360),
            radius: 260,
            repetitions: 3,
            repetitionInterval: 0.7,
            hapticFeedback: false
        )
    }

    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    ProCrownIcon(size: 48)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Starcat Pro")
                                .font(.title3.weight(.semibold))
                            if settings.isProUser {
                                ProStatusBadge()
                            }
                        }

                        Text(settings.isProUser ? "settings.pro.subtitle.active" : "settings.pro.subtitle.preview")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Label(LocalizedStringKey(settings.isProUser ? "settings.pro.status.active" : "settings.pro.status.free"),
                      systemImage: settings.isProUser ? "checkmark.seal.fill" : "lock.open")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(settings.isProUser ? .green : .secondary)

                if let expiration = subscriptionManager.entitlement.expirationDate, settings.isProUser {
                    Label {
                        HStack(spacing: 4) {
                            Text("settings.pro.status.expiration")
                            Text(expiration, style: .date)
                        }
                    } icon: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if showSuccessMessage {
                    Label("settings.pro.successBanner", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                }

                if let error = subscriptionManager.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        } footer: {
            Text("settings.pro.status.footer")
        }
    }

    private var productSection: some View {
        Section {
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
                ForEach(subscriptionManager.products, id: \.id) { product in
                    ProProductRow(
                        product: product,
                        isCurrent: subscriptionManager.entitlement.productID == product.id,
                        isBusy: subscriptionManager.isPurchasing
                    ) {
                        Task { await purchase(product) }
                    }
                }
            }
        } header: {
            Text("settings.pro.products.section")
        } footer: {
            Text("settings.pro.footer")
        }
    }

    private var benefitsSection: some View {
        Section {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], alignment: .leading, spacing: 8) {
                ProBenefitTile(
                    systemImage: "sparkles",
                    titleKey: "settings.pro.benefit.ai.title",
                    detailKey: "settings.pro.benefit.ai.detail"
                )
                ProBenefitTile(
                    systemImage: "magnifyingglass.circle.fill",
                    titleKey: "settings.pro.benefit.search.title",
                    detailKey: "settings.pro.benefit.search.detail"
                )
                ProBenefitTile(
                    systemImage: "bell.badge.fill",
                    titleKey: "settings.pro.benefit.release.title",
                    detailKey: "settings.pro.benefit.release.detail"
                )
                ProBenefitTile(
                    systemImage: "icloud.fill",
                    titleKey: "settings.pro.benefit.cloud.title",
                    detailKey: "settings.pro.benefit.cloud.detail"
                )
            }
        } header: {
            Text("settings.pro.benefits.section")
        } footer: {
            Text("settings.pro.benefits.footer")
        }
    }

    private var actionSection: some View {
        // 方案 A：原生设置行——整行可点、无灰底胶囊，外链行右侧用 ↗ 提示。
        Section {
            Button {
                Task { await subscriptionManager.restorePurchases() }
            } label: {
                ProAccountActionRow(
                    titleKey: "settings.pro.button.restore",
                    systemImage: "arrow.clockwise",
                    trailing: subscriptionManager.isRestoring ? .progress : .none
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(subscriptionManager.isRestoring)

            Button {
                isOfferCodeRedemptionPresented = true
            } label: {
                ProAccountActionRow(
                    titleKey: "settings.pro.button.redeemOfferCode",
                    systemImage: "giftcard",
                    trailing: .chevron
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Button {
                openURL(SubscriptionExternalLinks.manageSubscriptions)
            } label: {
                ProAccountActionRow(
                    titleKey: "settings.pro.button.manage",
                    systemImage: "person.crop.circle.badge.checkmark",
                    trailing: .externalLink
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        } header: {
            Text("settings.pro.account.section")
        } footer: {
            Text("settings.pro.account.footer")
        }
    }


    private func purchase(_ product: Product) async {
        let didActivate = await subscriptionManager.purchase(product)
        guard didActivate else { return }
        showSuccessMessage = true
        confettiTrigger += 1

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            showSuccessMessage = false
        }
    }
}

/// Pro 设置页 Account 区的单行操作样式（方案 A：macOS 系统设置行语义）。
///
/// - 左侧图标 + 标题占满行宽，英文长文案自然展开，不靠灰底胶囊。
/// - 右侧附件按动作类型区分：App 内 sheet 用 chevron、外链用 ↗、进行中用 ProgressView。
private struct ProAccountActionRow: View {

    enum Trailing {
        case none
        case chevron
        case externalLink
        case progress
    }

    let titleKey: LocalizedStringKey
    let systemImage: String
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            Text(titleKey)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            trailingView
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        case .externalLink:
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        case .progress:
            ProgressView()
                .controlSize(.small)
        }
    }
}

/// 单个 StoreKit 商品行。
private struct ProProductRow: View {
    let product: Product
    let isCurrent: Bool
    let isBusy: Bool
    let onPurchase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.callout.weight(.semibold))
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(product.displayPrice)
                        .font(.title3.weight(.semibold))
                    Text(LocalizedStringKey(isCurrent ? "settings.pro.plan.current" : "settings.pro.plan.available"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isCurrent ? .green : .secondary)
                }
            }

            Button {
                    onPurchase()
                } label: {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else if isCurrent {
                        Label("settings.pro.plan.current", systemImage: "checkmark.seal.fill")
                    } else {
                        Text(String(format: String.l10n("settings.pro.plan.subscribeFormat"),
                                    product.displayPrice))
                            .font(.callout.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || isCurrent)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(isCurrent ? 0.08 : 0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrent ? Color.green.opacity(0.45) : Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct ProBenefitTile: View {

    let systemImage: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 20, height: 20, alignment: .leading)

            Text(titleKey)
                .font(.caption.weight(.semibold))

            Text(detailKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }
}

struct ProCrownIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.yellow, .orange, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            Image(systemName: "crown.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .shadow(color: .orange.opacity(0.25), radius: 10, y: 4)
    }
}

struct ProStatusBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.orange, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
    }
}
