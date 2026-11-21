//
//  CompanionPairingViews.swift
//  Starcat
//
//  浏览器配对核对与设备管理。只展示用户可理解的授权范围，凭据不进入视图或剪贴板；
//  配对 Sheet 由现有全局 presenter 排队，避免与 MCP 审批同时抢占展示。
//

import SwiftUI

/// 六位码只用于人工核对，不提供“输入验证码即可批准”的旁路。
struct CompanionPairingApprovalSheet: View {
    let approval: CompanionPairingApproval
    let store: CompanionDeviceStore
    @Environment(\.starcatReduceMotion) private var reduceMotion

    private var browserName: String { approval.browser == "safari" ? "Safari" : "Chrome" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("companion.pairing.title")
                        .font(.title3.weight(.semibold))
                    Text("companion.pairing.compare")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                SheetCloseButton { store.reject(requestID: approval.id) }
            }

            browserIdentity
            verificationCode

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .accessibilityHidden(true)
                Text("companion.pairing.scope")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if store.approvalFailed {
                Text("companion.pairing.saveFailed")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button("companion.pairing.reject") { store.reject(requestID: approval.id) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("companion.pairing.approve") { store.approve(requestID: approval.id) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.approvalFailed)
    }

    private var browserIdentity: some View {
        HStack(spacing: 8) {
            Image(approval.browser)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            Text(verbatim: browserName)
                .font(.headline)
            if let version = approval.browserVersion, !version.isEmpty {
                Text(verbatim: version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var verificationCode: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Array(approval.code.enumerated()), id: \.offset) { _, digit in
                    Text(verbatim: String(digit))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .frame(width: 48, height: 56)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.12))
                        }
                }
            }
            // 核对时数字顺序必须与浏览器一致，VoiceOver 也应按单个数字读出。
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: approval.code.map { String($0) }.joined(separator: " ")))

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .accessibilityHidden(true)
                Text("companion.pairing.expires")
                Text(approval.expiresAt, style: .time)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 配对设备与全局手动 Key 分开管理；取消设备只撤销该设备，不轮换其他用户的凭据。
struct CompanionDeviceManagementSection: View {
    let store: CompanionDeviceStore
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var revoking: CompanionPairedDevice?
    @State private var actionFailed = false

    var body: some View {
        Section {
            if store.devices.isEmpty {
                Text("companion.devices.empty").foregroundStyle(.secondary)
            }
            ForEach(Array(store.devices.enumerated()), id: \.element.id) { index, device in
                CompanionDeviceRow(device: device, index: index, store: store) {
                    revoking = device
                }
                .transition(.opacity)
            }
            if actionFailed {
                Text("companion.devices.actionFailed").foregroundStyle(.primary)
            }
        } header: {
            SettingsSectionHeader("companion.devices.title", systemImage: "laptopcomputer.and.iphone")
        } footer: {
            Text("companion.devices.help")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.devices.map(\.id))
        .confirmationDialog(
            "companion.devices.revoke",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible
        ) {
            Button("companion.devices.revoke", role: .destructive) {
                guard let device = revoking else { return }
                do {
                    try store.revoke(deviceID: device.id)
                    actionFailed = false
                } catch {
                    actionFailed = true
                }
                revoking = nil
            }
        } message: {
            Text("companion.devices.revokeHelp")
        }
    }
}

/// 普通设备行没有单选导航：只补斑马纹、静态整行悬停和有界淡化，不引入跨行背景动画。
private struct CompanionDeviceRow: View {
    let device: CompanionPairedDevice
    let index: Int
    let store: CompanionDeviceStore
    let revoke: () -> Void
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var nameDraft = ""
    @State private var isRenaming = false
    @State private var renameFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isRenaming {
                    TextField("companion.devices.name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveName)
                    Button("common.save", action: saveName)
                } else {
                    Text(verbatim: device.name).fontWeight(.medium)
                    Spacer(minLength: 12)
                    Button("companion.devices.rename") {
                        nameDraft = device.name
                        isRenaming = true
                    }
                    Button("companion.devices.revoke", action: revoke)
                }
            }
            HStack {
                Text(verbatim: device.browserDescription)
                Spacer()
                Text("companion.devices.lastSeen")
                if let lastSeen = device.lastSeenAt {
                    Text(lastSeen, style: .relative)
                } else {
                    Text("companion.devices.notUsed")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Text("companion.devices.pairedAt")
                Text(device.pairedAt, style: .date)
                Spacer()
                Text("companion.devices.identifier")
                Text(verbatim: String(device.id.prefix(8)))
                    .fontDesign(.monospaced)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if renameFailed { Text("companion.devices.actionFailed").font(.caption) }
        }
        .padding(8)
        .background(Color.primary.opacity(hovered ? 0.07 : (index.isMultiple(of: 2) ? 0.025 : 0)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hovered)
    }

    private func saveName() {
        do {
            try store.rename(deviceID: device.id, name: nameDraft)
            isRenaming = false
            renameFailed = false
        } catch {
            renameFailed = true
        }
    }
}
