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
///
/// **Environment 约束**：本视图依赖 `@Environment(SubscriptionManager.self)` 与
/// `@Environment(DirectLicenseManager.self)`。SwiftUI
/// `.sheet` 根视图与 AppKit 自建 `NSHostingController` **不会**自动继承主窗订阅环境；
/// 必须通过 `ProPaywallSheet.hosted(context:dependencies:)` 注入，否则访问
/// environment 会触发 SwiftUI 运行时断言崩溃（`EnvironmentValues.subscript.getter`）。
struct ProPaywallSheet: View {
    let context: ProPaywallContext

    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(DirectLicenseManager.self) private var directLicenseManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var didActivate: Bool = false
    @State private var isOfferCodeRedemptionPresented = false
    @State private var directLicenseKey: String = ""
    @State private var selectedProductID: String?
    @State private var hoveredProductID: String?

    private var isDirectBuild: Bool { DistributionChannel.current.isDirect }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            benefits
            if isDirectBuild {
                directActions
            } else {
                products
                footerActions
            }
        }
        .padding(22)
        .frame(width: 420)
        .starcatOfferCodeRedemption(isPresented: $isOfferCodeRedemptionPresented) {
            didActivate = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            }
        }
        .task {
            if isDirectBuild {
                _ = await directLicenseManager.validateStoredLicense()
            } else {
                await subscriptionManager.loadProducts()
                selectDefaultProductIfNeeded()
                await subscriptionManager.refreshEntitlements()
            }
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
                } else if let error = paywallErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            SheetCloseButton { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var paywallErrorMessage: String? {
        isDirectBuild ? directLicenseManager.lastErrorMessage : subscriptionManager.lastErrorMessage
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
            VStack(spacing: 10) {
                ForEach(subscriptionManager.products, id: \.id) { product in
                    productSelectionButton(product)
                }

                if let selectedProduct {
                    Button {
                        Task { await purchase(selectedProduct) }
                    } label: {
                        HStack(spacing: 8) {
                            if subscriptionManager.isPurchasing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(purchaseButtonTitle(for: selectedProduct))
                                .font(.callout.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(subscriptionManager.isPurchasing)
                }
            }
        }
    }

    private var footerActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    paywallFooterButton("paywall.button.restore") {
                        Task { await subscriptionManager.restorePurchases() }
                    }
                    .disabled(subscriptionManager.isRestoring)

                    paywallFooterButton("paywall.button.redeemOfferCode") {
                        isOfferCodeRedemptionPresented = true
                    }

                    paywallFooterButton("paywall.button.manage") {
                        openURL(SubscriptionExternalLinks.manageSubscriptions)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    paywallFooterButton("paywall.button.restore") {
                        Task { await subscriptionManager.restorePurchases() }
                    }
                    .disabled(subscriptionManager.isRestoring)

                    paywallFooterButton("paywall.button.redeemOfferCode") {
                        isOfferCodeRedemptionPresented = true
                    }

                    paywallFooterButton("paywall.button.manage") {
                        openURL(SubscriptionExternalLinks.manageSubscriptions)
                    }
                }
            }
        }
    }

    private var directActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("paywall.direct.buyMonthly") {
                    Task { await openDirectCheckout(.monthly) }
                }
                .disabled(directLicenseManager.isRequestInFlight)

                // 与设置页一致：年付为推荐档，用系统默认着重色突出。
                Button("paywall.direct.buyYearly") {
                    Task { await openDirectCheckout(.yearly) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(directLicenseManager.isRequestInFlight)

                Button("paywall.direct.buyLifetime") {
                    Task { await openDirectCheckout(.lifetime) }
                }
                .disabled(directLicenseManager.isRequestInFlight)
            }

            Divider()

            Text("paywall.direct.activateTitle")
                .font(.callout.weight(.semibold))

            SecureField("settings.pro.direct.license.placeholder", text: $directLicenseKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()

                Button {
                    Task { await activateDirectLicense() }
                } label: {
                    // 与设置页 Direct 激活入口同图标，正向动作语义一致。
                    Label {
                        Text("settings.pro.direct.button.activate")
                    } icon: {
                        Image(systemName: "checkmark.seal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(directLicenseManager.isRequestInFlight || directLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("paywall.direct.footer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func paywallFooterButton(
        _ titleKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(titleKey)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// 商品行只负责选择方案，避免三个高饱和按钮同时争夺主操作层级。
    /// 购买动作统一收口到底部 CTA，用户可以先比较价格，再触发 StoreKit 确认。
    private func productSelectionButton(_ product: Product) -> some View {
        let isSelected = product.id == selectedProductID
        let isHovered = product.id == hoveredProductID

        return Button {
            selectedProductID = product.id
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(product.displayName)
                            .font(.callout.weight(.semibold))

                        if ProProductID(rawValue: product.id) == .yearly {
                            Text(yearlyBadgeText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color.orange.opacity(0.14))
                                )
                        }
                    }

                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let equivalent = yearlyMonthlyEquivalentText(for: product) {
                        Text(equivalent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 7) {
                    Text(planPriceText(for: product))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(productBackgroundColor(isSelected: isSelected, isHovered: isHovered))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.18),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(subscriptionManager.isPurchasing)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovering in
            hoveredProductID = isHovering ? product.id : nil
        }
    }

    private var selectedProduct: Product? {
        subscriptionManager.products.first { $0.id == selectedProductID }
    }

    private var yearlyBadgeText: String {
        guard let savingsPercent = yearlySavingsPercent else {
            return String.l10n("settings.pro.plan.badge.bestValue")
        }
        return String(
            format: String.l10n("paywall.plan.yearlySavingsFormat"),
            savingsPercent
        )
    }

    /// 价格始终来自 StoreKit；优惠比例仅用于当前已加载商品之间的展示比较。
    /// 这样不同商店地区调整价格时，付费墙不会继续显示过期的硬编码折扣。
    private var yearlySavingsPercent: Int? {
        guard
            let monthly = subscriptionManager.products.first(where: { ProProductID(rawValue: $0.id) == .monthly }),
            let yearly = subscriptionManager.products.first(where: { ProProductID(rawValue: $0.id) == .yearly })
        else { return nil }

        let monthlyAnnualPrice = NSDecimalNumber(decimal: monthly.price).doubleValue * 12
        let yearlyPrice = NSDecimalNumber(decimal: yearly.price).doubleValue
        guard monthlyAnnualPrice > 0, yearlyPrice < monthlyAnnualPrice else { return nil }
        return Int(((monthlyAnnualPrice - yearlyPrice) / monthlyAnnualPrice * 100).rounded())
    }

    private func yearlyMonthlyEquivalentText(for product: Product) -> String? {
        guard ProProductID(rawValue: product.id) == .yearly else { return nil }
        let monthlyEquivalent = product.price / 12
        let displayPrice = monthlyEquivalent.formatted(product.priceFormatStyle)
        return String(
            format: String.l10n("paywall.plan.yearlyMonthlyEquivalentFormat"),
            displayPrice
        )
    }

    private func planPriceText(for product: Product) -> String {
        let key: String
        switch ProProductID(rawValue: product.id) {
        case .monthly: key = "settings.pro.plan.price.monthlyFormat"
        case .yearly: key = "settings.pro.plan.price.yearlyFormat"
        case .lifetime: key = "settings.pro.plan.price.lifetimeFormat"
        case .none: return product.displayPrice
        }
        return String(format: String.l10n(key), product.displayPrice)
    }

    private func purchaseButtonTitle(for product: Product) -> String {
        let key: String
        switch ProProductID(rawValue: product.id) {
        case .monthly: key = "paywall.button.subscribeMonthlyFormat"
        case .yearly: key = "paywall.button.subscribeYearlyFormat"
        case .lifetime: key = "paywall.button.buyLifetimeFormat"
        case .none: key = "settings.pro.plan.subscribeFormat"
        }
        return String(format: String.l10n(key), product.displayPrice)
    }

    private func productBackgroundColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        }
        return Color.secondary.opacity(isHovered ? 0.10 : 0.06)
    }

    private func selectDefaultProductIfNeeded() {
        if let selectedProductID,
           subscriptionManager.products.contains(where: { $0.id == selectedProductID }) {
            return
        }

        // 年付是推荐档；如果商店暂未返回该商品，仍保证首个可用方案可购买。
        selectedProductID = subscriptionManager.products.first {
            ProProductID(rawValue: $0.id) == .yearly
        }?.id ?? subscriptionManager.products.first?.id
    }

    private func paywallBenefit(_ systemImage: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 18, alignment: .top)
            Text(key)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func purchase(_ product: Product) async {
        let activated = await subscriptionManager.purchase(product)
        guard activated else { return }
        didActivate = true
        try? await Task.sleep(for: .seconds(1))
        dismiss()
    }

    private func openDirectCheckout(_ plan: DirectCheckoutPlan) async {
        guard let url = await directLicenseManager.createCheckoutURL(for: plan) else { return }
        openURL(url)
    }

    private func activateDirectLicense() async {
        let activated = await directLicenseManager.activate(licenseKey: directLicenseKey)
        guard activated else { return }
        didActivate = true
        directLicenseKey = ""
        try? await Task.sleep(for: .seconds(1))
        dismiss()
    }
}

extension ProPaywallSheet {
    /// 付费墙 sheet 根视图的标准装配。
    @MainActor
    static func hosted(
        context: ProPaywallContext,
        dependencies: AppDependencies
    ) -> some View {
        ProPaywallSheet(context: context)
            .appSheetRootEnvironment(dependencies)
    }
}
