//
//  DataContributionConsentSheet.swift
//  Starcat
//
//  1.4.0 起的数据贡献一次性授权提示。这里只解释授权边界并写入现有账户级开关，
//  不参与快照构造、上传或重试，确保提示层不会改变旁路上报的可靠性语义。
//

import Foundation
import SwiftUI

/// 记录 1.4.0 数据贡献提示是否已由某个 GitHub 账户处理，并集中判断展示条件。
///
/// 使用 UserDefaults 而不是数据库迁移：该状态只是一次性 UI campaign 标记，不是业务授权真值；
/// 真正的授权仍由 `DataContributionSettingsModel` 写入账户数据库。这样老用户升级时无需改 schema，
/// 多账户又不会互相吞掉提示。
struct DataContributionConsentPromptPreferences {
    static let minimumAppVersion = "1.4.0"

    private static let campaignIdentifier = "v1_4_0"
    private let defaults: UserDefaults
    private let appVersionProvider: () -> String

    init(
        defaults: UserDefaults = .standard,
        appVersionProvider: @escaping () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        }
    ) {
        self.defaults = defaults
        self.appVersionProvider = appVersionProvider
    }

    /// 只有 1.4.0 及以后、登录账户与当前数据库一致、没有其他启动/登录覆盖层时才提示。
    ///
    /// `isContributionEnabled` 也参与判断，避免已经主动开启贡献的用户再次被打扰。
    func shouldPresent(
        authenticatedAccountID: Int64?,
        databaseAccountID: Int64?,
        isOnboardingActive: Bool,
        isAuthSheetPresented: Bool,
        isContributionEnabled: Bool
    ) -> Bool {
        guard let authenticatedAccountID,
              authenticatedAccountID == databaseAccountID,
              !isOnboardingActive,
              !isAuthSheetPresented,
              !isContributionEnabled,
              isEligibleAppVersion,
              !hasHandled(accountID: authenticatedAccountID)
        else {
            return false
        }
        return true
    }

    func hasHandled(accountID: Int64) -> Bool {
        defaults.bool(forKey: handledKey(accountID: accountID))
    }

    func markHandled(accountID: Int64) {
        defaults.set(true, forKey: handledKey(accountID: accountID))
    }

    private var isEligibleAppVersion: Bool {
        guard let currentVersion = AppStoreVersion(appVersionProvider()),
              let minimumVersion = AppStoreVersion(Self.minimumAppVersion)
        else {
            return false
        }
        return currentVersion >= minimumVersion
    }

    private func handledKey(accountID: Int64) -> String {
        "onboarding.dataContributionConsent.\(Self.campaignIdentifier).account.\(accountID)"
    }
}

/// 数据贡献一次性授权 Sheet。
///
/// 默认保持关闭，并用可审计的字段清单替代笼统隐私承诺；关闭按钮与“暂不参与”语义一致。
/// 用户确认后只更新现有账户级设置，实际上传仍等待下一次 Stars 全量同步成功。
struct DataContributionConsentSheet: View {
    @Binding var isEnabled: Bool

    let onClose: () -> Void
    let onSave: (Bool) -> Void

    static let sourceURL = URL(string: "https://github.com/starcat-app/Starcat")!

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            Text("onboarding.dataContribution.introduction")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            contributionToggle

            privacyExplanation

            openSourceLink

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button("onboarding.dataContribution.decline", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("onboarding.dataContribution.save") {
                    onSave(isEnabled)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        // 所有退出路径必须先记录“已处理”，因此禁用系统手势的无回调 dismiss；
        // Esc 仍由“暂不参与”的 cancelAction 正常响应。
        .interactiveDismissDisabled()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("onboarding.dataContribution.title")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()

            SheetCloseButton(action: onClose)
        }
    }

    private var contributionToggle: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text("onboarding.dataContribution.toggle")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("onboarding.dataContribution.uploadScope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var privacyExplanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("onboarding.dataContribution.privacy")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield.fill")
            }

            Label {
                Text("onboarding.dataContribution.anonymity")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "person.crop.circle.badge.checkmark")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var openSourceLink: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("onboarding.dataContribution.openSource")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: Self.sourceURL) {
                Label("onboarding.dataContribution.githubLink", systemImage: "arrow.up.right.square")
            }
            Text("github.com/starcat-app/Starcat")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
