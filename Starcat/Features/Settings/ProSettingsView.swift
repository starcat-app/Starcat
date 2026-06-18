//
//  ProSettingsView.swift
//  Starcat
//
//  HOM-151：Pro 开通模拟页。
//

import SwiftUI
import ConfettiSwiftUI

/// Pro 订阅设置页。
///
/// 当前没有 Apple 开发者账号，暂不接 StoreKit；点击开通只写入本地模拟状态，
/// 但后续彩纸动画、成功提示和头像 PRO 标识都走同一条状态链路。
struct ProSettingsTab: View {

    @Environment(AppSettings.self) private var settings

    @State private var confettiTrigger: Int = 0
    @State private var showSuccessMessage: Bool = false

    var body: some View {
        @Bindable var settings = settings

        return Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.yellow, .orange, .pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 48, height: 48)
                            Image(systemName: "crown.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: .orange.opacity(0.25), radius: 10, y: 4)

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

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        ProBenefitRow(
                            systemImage: "sparkles",
                            titleKey: "settings.pro.benefit.ai.title",
                            detailKey: "settings.pro.benefit.ai.detail"
                        )
                        ProBenefitRow(
                            systemImage: "paintpalette.fill",
                            titleKey: "settings.pro.benefit.badge.title",
                            detailKey: "settings.pro.benefit.badge.detail"
                        )
                        ProBenefitRow(
                            systemImage: "party.popper.fill",
                            titleKey: "settings.pro.benefit.confetti.title",
                            detailKey: "settings.pro.benefit.confetti.detail"
                        )
                    }

                    HStack {
                        Button {
                            simulateUpgrade(settings: settings)
                        } label: {
                            Label(settings.isProUser ? "settings.pro.button.active" : "settings.pro.button.simulate", systemImage: settings.isProUser ? "checkmark.seal.fill" : "crown.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.isProUser)

                        if settings.isProUser {
                            Button {
                                settings.updateProEntitlementMirror(isPro: false)
                                showSuccessMessage = false
                            } label: {
                                Label("settings.pro.button.reset", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.vertical, 2)
            } footer: {
                Text("settings.pro.footer")
            }

            if showSuccessMessage {
                Section {
                    Label("settings.pro.successBanner", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                }
            }
        }
        .formStyle(.grouped)
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

    private func simulateUpgrade(settings: AppSettings) {
        settings.updateProEntitlementMirror(isPro: true)
        showSuccessMessage = true
        confettiTrigger += 1

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            showSuccessMessage = false
        }
    }
}

private struct ProBenefitRow: View {

    let systemImage: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey)
                    .font(.callout.weight(.medium))
                Text(detailKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProStatusBadge: View {
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
