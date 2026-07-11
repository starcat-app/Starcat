//
//  ProSettingsView.swift
//  Starcat
//
//  Starcat Pro 订阅设置页。
//

import AppKit
import ConfettiSwiftUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

/// Pro 订阅设置页。
///
/// 本页只负责展示与触发购买动作；权益真相源在聚合 provider，业务门控在
/// `EntitlementGate`。这样 Settings 页重建、购买弹窗关闭或后续接服务端校验时，
/// 都不会让 Pro 状态分裂成多份。
struct ProSettingsTab: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(DirectLicenseManager.self) private var directLicenseManager
    @Environment(\.openURL) private var openURL

    @State private var confettiTrigger: Int = 0
    @State private var showSuccessMessage: Bool = false
    @State private var showCancelSubscriptionSuccess: Bool = false
    @State private var isOfferCodeRedemptionPresented = false
    @State private var isDirectPassPresented = false
    @State private var isDirectLicensePresented = false
    @State private var showDirectPassSavedMessage = false
    @State private var directLicenseKey: String = ""

    private var isDirectBuild: Bool { DistributionChannel.current.isDirect }

    var body: some View {
        Form {
            heroSection
            benefitsSection
            if isDirectBuild {
                directPassSection
                directLicenseSection
                if !settings.isProUser {
                    directCheckoutSection
                }
                directAccountSection
                if directLicenseManager.storedCredential?.subscriptionID != nil {
                    directSubscriptionSection
                }
                directUpdateSection
            } else {
                productSection
                actionSection
            }

        }
        .formStyle(.grouped)
        .sheet(isPresented: $isDirectPassPresented) {
            DirectProPassSheet(
                data: directPassData,
                onClose: { isDirectPassPresented = false },
                onDownload: { saveDirectPassImage() }
            )
            .frame(width: 640, height: 720)
        }
        .sheet(isPresented: $isDirectLicensePresented) {
            DirectLicenseSheet(
                data: directPassData,
                maskedLicenseKey: directLicenseManager.storedCredential.map { maskedLicenseKey($0.licenseKey) },
                devices: directLicenseManager.licenseDevices,
                isLoadingDevices: directLicenseManager.isRequestInFlight,
                canOpenPortal: directLicenseManager.storedCredential != nil,
                canDeactivateCurrentMac: directLicenseManager.storedCredential != nil,
                onClose: { isDirectLicensePresented = false },
                onCopyLicense: { copyStoredDirectLicense() },
                onOpenPortal: { Task { await openCustomerPortal() } },
                onRefreshDevices: { Task { await directLicenseManager.refreshLicenseDevices() } },
                onDeactivateCurrentMac: { Task { await deactivateDirectLicense() } },
                onDeactivateDevice: { instanceID in
                    Task { await directLicenseManager.deactivateLicenseDevice(instanceID: instanceID) }
                }
            )
            .frame(width: 560, height: 520)
            .task {
                await directLicenseManager.refreshLicenseDevices()
            }
        }
        .starcatOfferCodeRedemption(isPresented: $isOfferCodeRedemptionPresented) {
            showSuccessMessage = true
            confettiTrigger += 1
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                showSuccessMessage = false
            }
        }
        .task {
            if isDirectBuild {
                _ = await directLicenseManager.validateStoredLicenseIfNeeded()
            } else {
                await subscriptionManager.loadProducts()
                await subscriptionManager.refreshEntitlements()
            }
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

                if let expiration = activeExpirationDate, settings.isProUser {
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

                if let error = subscriptionManager.lastErrorMessage, !isDirectBuild {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = directLicenseManager.lastErrorMessage, isDirectBuild {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        } footer: {
            Text(LocalizedStringKey(isDirectBuild ? "settings.pro.direct.status.footer" : "settings.pro.status.footer"))
        }
    }

    private var directLicenseSection: some View {
        Section {
            if let credential = directLicenseManager.storedCredential {
                DirectLicenseKeyRow(
                    maskedKey: maskedLicenseKey(credential.licenseKey),
                    suffix: currentLicenseSuffix
                ) {
                    copyToPasteboard(credential.licenseKey)
                }
            }

            SecureField("settings.pro.direct.license.placeholder", text: $directLicenseKey)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    Task { await activateDirectLicense() }
                } label: {
                    Label("settings.pro.direct.button.activate", systemImage: "checkmark.seal")
                }
                .disabled(directLicenseManager.isRequestInFlight || directLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await validateDirectLicense() }
                } label: {
                    Label("settings.pro.direct.button.validate", systemImage: "arrow.clockwise")
                }
                .disabled(directLicenseManager.isRequestInFlight || directLicenseManager.storedCredential == nil)

                Button(role: .destructive) {
                    Task { await deactivateDirectLicense() }
                } label: {
                    Label("settings.pro.direct.button.deactivate", systemImage: "xmark.circle")
                }
                .disabled(directLicenseManager.isRequestInFlight || directLicenseManager.storedCredential == nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } header: {
            Text("settings.pro.direct.section")
        } footer: {
            Text("settings.pro.direct.footer")
        }
    }

    private var directPassSection: some View {
        Section {
            DirectProPassPreviewCard(
                data: directPassData,
                onOpenPass: { isDirectPassPresented = true },
                onOpenLicense: { isDirectLicensePresented = true }
            )

            if showDirectPassSavedMessage {
                Label("settings.pro.direct.pass.saved", systemImage: "square.and.arrow.down.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        } header: {
            Text("settings.pro.direct.pass.section")
        } footer: {
            Text("settings.pro.direct.pass.footer")
        }
    }

    private var directAccountSection: some View {
        Section {
            Button {
                Task { await openCustomerPortal() }
            } label: {
                ProAccountActionRow(
                    titleKey: "settings.pro.direct.portal.button",
                    systemImage: "creditcard",
                    trailing: directLicenseManager.isRequestInFlight ? .progress : .externalLink
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(directLicenseManager.isRequestInFlight || directLicenseManager.storedCredential == nil)
        } header: {
            Text("settings.pro.direct.portal.section")
        } footer: {
            Text("settings.pro.direct.portal.footer")
        }
    }

    private var directUpdateSection: some View {
        let updateController = dependencies.directUpdateController

        return Section {
            Button {
                dependencies.directUpdateController.checkForUpdates()
            } label: {
                ProAccountActionRow(
                    titleKey: "settings.pro.direct.updates.check",
                    systemImage: "arrow.triangle.2.circlepath",
                    trailing: .none
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!dependencies.directUpdateController.canCheckForUpdates)

            Toggle("settings.pro.direct.updates.autoCheck", isOn: Binding(
                get: { updateController.automaticallyChecksForUpdates },
                set: { updateController.automaticallyChecksForUpdates = $0 }
            ))
            .disabled(!dependencies.directUpdateController.isConfigured)

            Toggle("settings.pro.direct.updates.autoDownload", isOn: Binding(
                get: { updateController.automaticallyDownloadsUpdates },
                set: { updateController.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!dependencies.directUpdateController.isConfigured || !updateController.automaticallyChecksForUpdates)
        } header: {
            Text("settings.pro.direct.updates.section")
        } footer: {
            Text(LocalizedStringKey(dependencies.directUpdateController.isConfigured
                                    ? "settings.pro.direct.updates.footer"
                                    : "settings.pro.direct.updates.notConfigured"))
        }
    }

    private var directSubscriptionSection: some View {
        Section {
            if let snapshot = directLicenseManager.lastSubscriptionSnapshot {
                Label {
                    Text(LocalizedStringKey(snapshot.currentPeriodEnd == nil
                                            ? "settings.pro.direct.cancel.scheduled"
                                            : "settings.pro.direct.cancel.scheduledWithPeriod"))
                } icon: {
                    Image(systemName: "calendar.badge.minus")
                }
                .foregroundStyle(.green)
            } else if showCancelSubscriptionSuccess {
                Label("settings.pro.direct.cancel.scheduled", systemImage: "calendar.badge.minus")
                    .foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button("settings.pro.direct.cancel.button", role: .destructive) {
                    Task { await cancelDirectSubscription() }
                }
                .disabled(directLicenseManager.isRequestInFlight)
            }
        } header: {
            Text("settings.pro.direct.cancel.section")
        } footer: {
            Text("settings.pro.direct.cancel.footer")
        }
    }

    private var directCheckoutSection: some View {
        Section {
            HStack {
                Spacer()

                Button {
                    Task { await openDirectCheckout(.monthly) }
                } label: {
                    Label("settings.pro.direct.checkout.monthly", systemImage: "calendar")
                }
                .disabled(directLicenseManager.isRequestInFlight)

                Button {
                    Task { await openDirectCheckout(.yearly) }
                } label: {
                    Label("settings.pro.direct.checkout.yearly", systemImage: "calendar.badge.clock")
                }
                .buttonStyle(.borderedProminent)
                .disabled(directLicenseManager.isRequestInFlight)

                Button {
                    Task { await openDirectCheckout(.lifetime) }
                } label: {
                    Label("settings.pro.direct.checkout.lifetime", systemImage: "infinity")
                }
                .disabled(directLicenseManager.isRequestInFlight)
            }
        } header: {
            Text("settings.pro.direct.checkout.section")
        } footer: {
            Text("settings.pro.direct.checkout.footer")
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
                    systemImage: "shippingbox.fill",
                    titleKey: "settings.pro.benefit.repoContext.title",
                    detailKey: "settings.pro.benefit.repoContext.detail"
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
        showActivationSuccess()
    }

    private func activateDirectLicense() async {
        let didActivate = await directLicenseManager.activate(licenseKey: directLicenseKey)
        guard didActivate else { return }
        directLicenseKey = ""
        showActivationSuccess()
    }

    private func validateDirectLicense() async {
        let didActivate = await directLicenseManager.validateStoredLicense()
        guard didActivate else { return }
        showActivationSuccess()
    }

    private func deactivateDirectLicense() async {
        _ = await directLicenseManager.deactivateStoredLicense()
    }

    private func cancelDirectSubscription() async {
        let didCancel = await directLicenseManager.cancelStoredMonthlySubscription()
        guard didCancel else { return }
        showCancelSubscriptionSuccess = true
    }

    private func openCustomerPortal() async {
        guard let url = await directLicenseManager.createCustomerPortalURL() else { return }
        openURL(url)
    }

    private func openDirectCheckout(_ plan: DirectCheckoutPlan) async {
        guard let url = await directLicenseManager.createCheckoutURL(for: plan) else { return }
        openURL(url)
    }

    private func showActivationSuccess() {
        showSuccessMessage = true
        confettiTrigger += 1

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            showSuccessMessage = false
        }
    }

    private var activeExpirationDate: Date? {
        isDirectBuild ? directLicenseManager.entitlement.expirationDate : subscriptionManager.entitlement.expirationDate
    }

    private var directPassData: DirectProPassData {
        let expirationText = directLicenseManager.lastSnapshot?.expiresAt.map {
            DateFormatter.starcatLicenseDate.string(from: $0)
        } ?? String.l10n("settings.pro.direct.pass.noExpiration")
        let validatedText = (directLicenseManager.lastSnapshot?.validatedAt ?? directLicenseManager.validationRecord.lastSuccessAt).map {
            DateFormatter.starcatLicenseDateTime.string(from: $0)
        } ?? String.l10n("settings.pro.direct.pass.empty")
        let suffix = currentLicenseSuffix

        return DirectProPassData(
            isActive: settings.isProUser,
            planText: directPlanText,
            statusText: directRuntimeStateText,
            licenseSuffix: suffix,
            displayLicense: suffix.map { String(format: String.l10n("settings.pro.direct.pass.licenseSuffix"), $0) }
                ?? String.l10n("settings.pro.direct.pass.empty"),
            seatText: directSeatText,
            expirationText: expirationText,
            validatedText: validatedText
        )
    }

    private var currentLicenseSuffix: String? {
        directLicenseManager.lastSnapshot?.licenseKeySuffix
            ?? directLicenseManager.storedCredential.map { String($0.licenseKey.suffix(4)) }
    }

    private var directPlanText: String {
        switch directLicenseManager.storedCredential?.plan ?? directLicenseManager.validationRecord.plan {
        case .monthly:
            return String.l10n("settings.pro.direct.pass.plan.monthly")
        case .yearly:
            return String.l10n("settings.pro.direct.pass.plan.yearly")
        case .lifetime:
            return String.l10n("settings.pro.direct.pass.plan.lifetime")
        case .none:
            return settings.isProUser ? String.l10n("settings.pro.direct.pass.plan.pro") : String.l10n("settings.pro.direct.pass.plan.free")
        }
    }

    private var directRuntimeStateText: String {
        switch directLicenseManager.runtimeState {
        case .verifiedActive:
            return String.l10n("settings.pro.direct.pass.status.verified")
        case .localActive:
            return String.l10n("settings.pro.direct.pass.status.local")
        case .expired:
            return String.l10n("settings.pro.direct.pass.status.expired")
        case .revoked:
            return String.l10n("settings.pro.direct.pass.status.revoked")
        case .none:
            return String.l10n("settings.pro.direct.pass.status.free")
        }
    }

    private var directSeatText: String {
        guard let used = directLicenseManager.lastSnapshot?.activationUsed,
              let limit = directLicenseManager.lastSnapshot?.activationLimit,
              limit > 0
        else {
            return String.l10n("settings.pro.direct.pass.seats.unknown")
        }
        return String(format: String.l10n("settings.pro.direct.pass.seats.format"), used, limit)
    }

    private func maskedLicenseKey(_ licenseKey: String) -> String {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        return "\(trimmed.prefix(4))••••\(trimmed.suffix(4))"
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func copyStoredDirectLicense() {
        guard let licenseKey = directLicenseManager.storedCredential?.licenseKey else { return }
        copyToPasteboard(licenseKey)
    }

    private func saveDirectPassImage() {
        guard let url = DirectProPassExporter.saveImage(data: directPassData) else { return }
        AppLog.ui.info("Direct Pro pass saved: \(url.path, privacy: .public)")
        showDirectPassSavedMessage = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            showDirectPassSavedMessage = false
        }
    }
}

/// Direct 版通行证展示数据。
///
/// 设置页、弹窗和导出图共用同一个数据快照，避免 UI 上出现不同步的状态文案。
private struct DirectProPassData {
    let isActive: Bool
    let planText: String
    let statusText: String
    let licenseSuffix: String?
    let displayLicense: String
    let seatText: String
    let expirationText: String
    let validatedText: String
}

/// 设置页里的 Direct Pro Pass 入口。
///
/// 它只负责预览和打开弹窗，完整通行证放到 `DirectProPassSheet`，避免设置页 Form
/// 变成低质信息堆叠。
private struct DirectProPassPreviewCard: View {
    let data: DirectProPassData
    let onOpenPass: () -> Void
    let onOpenLicense: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                DirectPassMiniArtwork(data: data)
                    .frame(width: 92, height: 128)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.pro.direct.pass.title")
                        .font(.headline.weight(.semibold))

                    Text(data.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        DirectPassPill(text: data.planText, color: .orange)
                        DirectPassPill(text: data.seatText, color: .blue)
                    }
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Button(action: onOpenPass) {
                    Label("settings.pro.direct.pass.button.view", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .focusEffectDisabled()

                Button(action: onOpenLicense) {
                    Label("settings.pro.direct.license.button.manage", systemImage: "key.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .focusEffectDisabled()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(data.isActive ? Color.orange.opacity(0.46) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }
}

/// Direct Pro Pass 弹窗。
///
/// 这里参考实体通行证的交互模型：通行证本体在中央，操作按钮放到底部工具区；
/// 第二期设备列表未完成前，只提供“解绑当前 Mac”，不承诺管理其他设备。
private struct DirectProPassSheet: View {
    let data: DirectProPassData
    let onClose: () -> Void
    let onDownload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wallet.pass.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.cyan.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.pro.direct.pass.sheet.title")
                        .font(.title3.weight(.semibold))
                    Text("settings.pro.direct.pass.sheet.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                SheetCloseButton(action: onClose)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            VStack(spacing: 16) {
                DirectInteractivePassArtwork(data: data)
                    .frame(width: 326, height: 452)
                    .shadow(color: .black.opacity(0.34), radius: 24, y: 16)

                Button(action: onDownload) {
                    Label("settings.pro.direct.pass.button.download", systemImage: "square.and.arrow.down")
                        .frame(width: 210)
                }
                .buttonStyle(.borderedProminent)
                .focusEffectDisabled()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 22)
        }
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [.cyan.opacity(0.12), .clear], center: .topLeading, startRadius: 40, endRadius: 420)
                RadialGradient(colors: [.orange.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 60, endRadius: 420)
            }
        )
    }
}

private struct DirectLicenseSheet: View {
    let data: DirectProPassData
    let maskedLicenseKey: String?
    let devices: [DirectLicenseDevice]
    let isLoadingDevices: Bool
    let canOpenPortal: Bool
    let canDeactivateCurrentMac: Bool
    let onClose: () -> Void
    let onCopyLicense: () -> Void
    let onOpenPortal: () -> Void
    let onRefreshDevices: () -> Void
    let onDeactivateCurrentMac: () -> Void
    let onDeactivateDevice: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.cyan.opacity(0.9), .yellow.opacity(0.86)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "key.fill")
                            .font(.system(size: 36, weight: .black))
                            .foregroundStyle(Color(red: 0.05, green: 0.06, blue: 0.08))
                    }
                    .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(data.isActive ? "settings.pro.direct.license.sheet.activeTitle" : "settings.pro.direct.license.sheet.freeTitle")
                            .font(.title.weight(.bold))
                        Text("settings.pro.direct.license.sheet.subtitle")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(data.isActive ? "settings.pro.direct.pass.badge.active" : "settings.pro.direct.pass.badge.free")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(data.isActive ? .green : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill((data.isActive ? Color.green : Color.secondary).opacity(0.16)))

                SheetCloseButton(action: onClose)
                    .padding(.leading, 12)
            }
            .padding(28)

            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Text(maskedLicenseKey ?? data.displayLicense)
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Spacer()

                    Button(action: onCopyLicense) {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .focusEffectDisabled()
                    .disabled(data.licenseSuffix == nil)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }

                DirectPassDeviceList(
                    devices: devices,
                    isLoading: isLoadingDevices,
                    onRefresh: onRefreshDevices,
                    onDeactivate: onDeactivateDevice
                )
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 16)

            Divider()

            HStack(spacing: 10) {
                DirectPassToolbarButton(titleKey: "settings.pro.direct.portal.button", systemImage: "creditcard", action: onOpenPortal)
                    .disabled(!canOpenPortal)
                DirectPassToolbarButton(titleKey: "settings.pro.direct.pass.button.deactivateMac", systemImage: "xmark.circle", role: .destructive, action: onDeactivateCurrentMac)
                    .disabled(!canDeactivateCurrentMac)
            }
            .padding(18)
        }
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [.green.opacity(0.10), .clear], center: .topLeading, startRadius: 60, endRadius: 420)
            }
        )
    }
}

private struct DirectPassDetailRow: View {
    let titleKey: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DirectPassDeviceList: View {
    let devices: [DirectLicenseDevice]
    let isLoading: Bool
    let onRefresh: () -> Void
    let onDeactivate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("settings.pro.direct.devices.section")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onRefresh) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(isLoading)
            }

            if devices.isEmpty {
                Text("settings.pro.direct.devices.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(devices) { device in
                        DirectPassDeviceRow(device: device) {
                            onDeactivate(device.instanceID)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct DirectPassDeviceRow: View {
    let device: DirectLicenseDevice
    let onDeactivate: () -> Void

    private var displayName: String {
        let trimmed = device.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil)
            ?? String(format: String.l10n("settings.pro.direct.devices.unnamed"), String(device.instanceID.suffix(4)))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.isCurrentDevice ? "desktopcomputer.and.macbook" : "desktopcomputer")
                .foregroundStyle(device.isCurrentDevice ? .blue : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    if device.isCurrentDevice {
                        Text("settings.pro.direct.devices.current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }

                Text(device.createdAt.map { DateFormatter.starcatLicenseDate.string(from: $0) } ?? device.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: onDeactivate) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("settings.pro.direct.devices.deactivate")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct DirectInteractivePassArtwork: View {
    let data: DirectProPassData

    @State private var hoverLocation: CGPoint?
    @State private var isHovering = false

    private var xRotation: Angle {
        guard let hoverLocation else { return .zero }
        return .degrees(Double((0.5 - hoverLocation.y) * 12))
    }

    private var yRotation: Angle {
        guard let hoverLocation else { return .zero }
        return .degrees(Double((hoverLocation.x - 0.5) * 14))
    }

    var body: some View {
        GeometryReader { proxy in
            DirectProPassArtwork(data: data, isAnimatedPreview: true)
                .overlay {
                    DirectPassGlare(location: hoverLocation)
                        .opacity(isHovering ? 1 : 0)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .rotation3DEffect(xRotation, axis: (x: 1, y: 0, z: 0), perspective: 0.72)
                .rotation3DEffect(yRotation, axis: (x: 0, y: 1, z: 0), perspective: 0.72)
                .scaleEffect(isHovering ? 1.018 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: hoverLocation)
                .animation(.easeOut(duration: 0.18), value: isHovering)
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        isHovering = true
                        hoverLocation = CGPoint(
                            x: max(0, min(1, location.x / max(proxy.size.width, 1))),
                            y: max(0, min(1, location.y / max(proxy.size.height, 1)))
                        )
                    case .ended:
                        isHovering = false
                        hoverLocation = nil
                    }
                }
        }
    }
}

private struct DirectPassGlare: View {
    let location: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let point = CGPoint(
                x: (location?.x ?? 0.5) * proxy.size.width,
                y: (location?.y ?? 0.5) * proxy.size.height
            )

            RadialGradient(
                colors: [
                    .white.opacity(0.26),
                    .cyan.opacity(0.10),
                    .clear
                ],
                center: UnitPoint(
                    x: point.x / max(proxy.size.width, 1),
                    y: point.y / max(proxy.size.height, 1)
                ),
                startRadius: 10,
                endRadius: 190
            )
            .blendMode(.screen)
        }
    }
}

private struct DirectProPassArtwork: View {
    static let exportWidth: CGFloat = 720
    static let exportHeight: CGFloat = 1000

    let data: DirectProPassData
    var isAnimatedPreview = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let scale = min(width / Self.exportWidth, height / Self.exportHeight)

            passBody
                .frame(width: Self.exportWidth, height: Self.exportHeight)
                .scaleEffect(scale)
                .frame(width: width, height: height)
        }
    }

    private var passBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.04, blue: 0.16),
                            Color(red: 0.03, green: 0.05, blue: 0.12),
                            Color(red: 0.12, green: 0.05, blue: 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if isAnimatedPreview {
                // 预览态可以使用 Metal 动态 shader；导出 PNG 时保持静态 Canvas，
                // 因为 ImageRenderer 不会捕获 SwiftUI Metal shader 帧。
                DotsFlowBackground(
                    style: .snake,
                    tint: .cyan,
                    background: .black,
                    speed: 0.32,
                    brightness: 0.9,
                    dotSize: 0.92,
                    gridDensity: 1.15,
                    patternScale: 0.86,
                    vignette: 0.22
                )
                .blendMode(.plusLighter)
                .opacity(0.58)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            }

            DirectPassConstellation(isDense: isAnimatedPreview)
                .opacity(isAnimatedPreview ? 0.86 : 0.78)
                .padding(28)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STARCAT")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .tracking(8)
                        Text("PRO_PASS")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .tracking(4)
                    }

                    Spacer()

                    Text(data.licenseSuffix.map { "••\($0)" } ?? "FREE")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.50))
                }

                Spacer(minLength: 0)

                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.85), .yellow.opacity(0.92)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: data.isActive ? "checkmark" : "star.fill")
                        .font(.system(size: 70, weight: .black))
                        .foregroundStyle(Color(red: 0.02, green: 0.04, blue: 0.10))
                }
                .frame(width: 132, height: 132)
                .shadow(color: .cyan.opacity(0.22), radius: 28, y: 10)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 10) {
                    Text(data.planText.uppercased())
                        .font(.system(size: 28, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .tracking(4)
                    Text("BOARDING_PASS")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.46))
                        .tracking(6)
                }
                .padding(.bottom, 34)

                VStack(alignment: .leading, spacing: 16) {
                    DirectPassTerminalRow(label: "STATUS", value: data.isActive ? "ACTIVE" : "FREE")
                    DirectPassTerminalRow(label: "LICENSE", value: data.displayLicense.uppercased())
                    DirectPassTerminalRow(label: "SEATS", value: data.seatText.uppercased())
                    DirectPassTerminalRow(label: "CHECKED", value: data.validatedText.uppercased())
                }

                Spacer(minLength: 0)

                Rectangle()
                    .fill(.white.opacity(0.14))
                    .frame(height: 1)
                    .padding(.horizontal, -34)
                    .padding(.bottom, 24)

                HStack {
                    Text("STARCAT DIRECT")
                    Text("·")
                    Text("V1")
                    Spacer()
                    Text("KEEP_STARRING")
                }
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.46))
                .tracking(2.5)
            }
            .padding(44)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.cyan.opacity(0.75), .purple.opacity(0.45), .orange.opacity(0.52)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.4
                )
        }
    }
}

private struct DirectPassMiniArtwork: View {
    let data: DirectProPassData

    var body: some View {
        DirectProPassArtwork(data: data)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct DirectPassPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct DirectPassToolbarButton: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(titleKey, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .focusEffectDisabled()
    }
}

private struct DirectPassTerminalRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label)
                .frame(width: 104, alignment: .leading)
                .foregroundStyle(.white.opacity(0.34))
            Text(">")
                .foregroundStyle(.white.opacity(0.26))
            Text(value)
                .foregroundStyle(.pink.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.56)
        }
        .font(.system(size: 20, weight: .bold, design: .monospaced))
    }
}

private struct DirectPassConstellation: View {
    var isDense = false

    private let points: [CGPoint] = [
        CGPoint(x: 0.08, y: 0.16), CGPoint(x: 0.18, y: 0.23), CGPoint(x: 0.30, y: 0.18),
        CGPoint(x: 0.44, y: 0.28), CGPoint(x: 0.61, y: 0.18), CGPoint(x: 0.78, y: 0.24),
        CGPoint(x: 0.88, y: 0.14), CGPoint(x: 0.16, y: 0.42), CGPoint(x: 0.34, y: 0.50),
        CGPoint(x: 0.55, y: 0.45), CGPoint(x: 0.72, y: 0.52), CGPoint(x: 0.88, y: 0.48)
    ]

    var body: some View {
        Canvas { context, size in
            drawPixelArchipelagos(context: context, size: size)

            for index in points.indices {
                let point = CGPoint(x: points[index].x * size.width, y: points[index].y * size.height)
                let rect = CGRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4)
                context.fill(Path(ellipseIn: rect), with: .color(index.isMultiple(of: 2) ? .cyan.opacity(0.82) : .purple.opacity(0.78)))

                if index > 0 {
                    let previous = CGPoint(x: points[index - 1].x * size.width, y: points[index - 1].y * size.height)
                    var path = Path()
                    path.move(to: previous)
                    path.addLine(to: point)
                    context.stroke(path, with: .color(.cyan.opacity(0.15)), lineWidth: 1)
                }
            }

            let starStep: CGFloat = isDense ? 22 : 28
            for x in stride(from: 0, through: size.width, by: starStep) {
                for y in stride(from: 0, through: size.height, by: starStep) {
                    if Int((x * 0.7 + y) / starStep).isMultiple(of: isDense ? 4 : 5) {
                        let rect = CGRect(x: x, y: y, width: 2.0, height: 2.0)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(isDense ? 0.16 : 0.12)))
                    }
                }
            }
        }
    }

    /// 用固定点阵簇模拟 Vibe Island 那种像素地图感；保持纯 Canvas，
    /// 这样通行证导出 PNG 时也能看到同一套静态底纹。
    private func drawPixelArchipelagos(context: GraphicsContext, size: CGSize) {
        let clusters: [(CGPoint, Int, Int)] = [
            (CGPoint(x: 0.14, y: 0.15), 8, 7),
            (CGPoint(x: 0.34, y: 0.14), 10, 6),
            (CGPoint(x: 0.72, y: 0.16), 9, 8),
            (CGPoint(x: 0.18, y: 0.36), 11, 7),
            (CGPoint(x: 0.52, y: 0.38), 12, 8),
            (CGPoint(x: 0.82, y: 0.42), 8, 9),
            (CGPoint(x: 0.28, y: 0.68), 10, 7),
            (CGPoint(x: 0.68, y: 0.72), 11, 8)
        ]
        let pitch: CGFloat = isDense ? 13 : 15
        let pixel: CGFloat = isDense ? 4.1 : 3.7

        for (center, columns, rows) in clusters {
            let origin = CGPoint(
                x: center.x * size.width - CGFloat(columns) * pitch * 0.5,
                y: center.y * size.height - CGFloat(rows) * pitch * 0.5
            )

            for column in 0..<columns {
                for row in 0..<rows {
                    let normalizedX = (CGFloat(column) / CGFloat(max(columns - 1, 1)) - 0.5) * 2
                    let normalizedY = (CGFloat(row) / CGFloat(max(rows - 1, 1)) - 0.5) * 2
                    let distance = normalizedX * normalizedX + normalizedY * normalizedY
                    let hash = (column * 17 + row * 31 + columns * 7 + rows * 11) % 9
                    guard distance < 0.82 || hash == 0 || hash == 3 else { continue }

                    let x = origin.x + CGFloat(column) * pitch
                    let y = origin.y + CGFloat(row) * pitch
                    let opacity = 0.10 + max(0, 0.34 - distance * 0.18)
                    let color: Color = hash.isMultiple(of: 4) ? .purple : .cyan
                    let rect = CGRect(x: x, y: y, width: pixel, height: pixel)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.6), with: .color(color.opacity(opacity)))

                    if isDense, hash == 0 {
                        let halo = CGRect(x: x - 1.2, y: y - 1.2, width: pixel + 2.4, height: pixel + 2.4)
                        context.fill(Path(ellipseIn: halo), with: .color(color.opacity(0.08)))
                    }
                }
            }
        }
    }
}

@MainActor
private enum DirectProPassExporter {
    static func saveImage(data: DirectProPassData) -> URL? {
        let content = DirectProPassArtwork(data: data)
            .frame(width: DirectProPassArtwork.exportWidth, height: DirectProPassArtwork.exportHeight)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(
            width: DirectProPassArtwork.exportWidth,
            height: DirectProPassArtwork.exportHeight
        )

        guard let image = renderer.nsImage,
              let pngData = pngData(from: image) else {
            AppLog.ui.error("DirectProPassExporter: failed to render pass image")
            return nil
        }

        let panel = NSSavePanel()
        panel.title = String.l10n("settings.pro.direct.pass.savePanel.title")
        panel.message = String.l10n("settings.pro.direct.pass.savePanel.message")
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = data.licenseSuffix.map { "Starcat-Pro-Pass-\($0).png" } ?? "Starcat-Pro-Pass.png"
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            AppLog.ui.error("DirectProPassExporter: save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private struct DirectLicenseKeyRow: View {
    let maskedKey: String
    let suffix: String?
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(maskedKey)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                if let suffix {
                    Text(String(format: String.l10n("settings.pro.direct.currentFormat"), suffix))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                onCopy()
            } label: {
                Label("settings.pro.direct.button.copyLicense", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

private extension DateFormatter {
    static let starcatLicenseDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let starcatLicenseDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
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

    private var productID: ProProductID? {
        ProProductID(rawValue: product.id)
    }

    private var title: String {
        if product.displayName.isEmpty == false {
            return product.displayName
        }
        switch productID {
        case .monthly: return String.l10n("settings.pro.plan.monthly.title")
        case .yearly: return String.l10n("settings.pro.plan.yearly.title")
        case .lifetime: return String.l10n("settings.pro.plan.lifetime.title")
        case .none: return product.id
        }
    }

    private var subtitleKey: LocalizedStringKey {
        switch productID {
        case .monthly: return "settings.pro.plan.monthly.subtitle"
        case .yearly: return "settings.pro.plan.yearly.subtitle"
        case .lifetime: return "settings.pro.plan.lifetime.subtitle"
        case .none: return "settings.pro.plan.available"
        }
    }

    private var priceText: String {
        switch productID {
        case .monthly:
            return String(format: String.l10n("settings.pro.plan.price.monthlyFormat"), product.displayPrice)
        case .yearly:
            return String(format: String.l10n("settings.pro.plan.price.yearlyFormat"), product.displayPrice)
        case .lifetime:
            return String(format: String.l10n("settings.pro.plan.price.lifetimeFormat"), product.displayPrice)
        case .none:
            return product.displayPrice
        }
    }

    private var badgeKey: LocalizedStringKey? {
        switch productID {
        case .yearly: return "settings.pro.plan.badge.bestValue"
        case .lifetime: return "settings.pro.plan.badge.lifetime"
        default: return nil
        }
    }

    private var purchaseButtonKey: LocalizedStringKey {
        productID == .lifetime ? "settings.pro.plan.buy" : "settings.pro.plan.subscribe"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))

                    if let badgeKey {
                        Text(badgeKey)
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

                Text(subtitleKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(isCurrent ? "settings.pro.plan.current" : "settings.pro.plan.available")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isCurrent ? .green : .secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Text(priceText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()

                Button {
                    onPurchase()
                } label: {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else if isCurrent {
                        Label("settings.pro.plan.current", systemImage: "checkmark.seal.fill")
                    } else {
                        Text(purchaseButtonKey)
                            .font(.callout.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || isCurrent)
                .fixedSize()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
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
