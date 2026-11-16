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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("companion.pairing.title").font(.title3.weight(.semibold))
                    Text("companion.pairing.compare")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                SheetCloseButton { store.reject(requestID: approval.id) }
            }
            Text(verbatim: approval.name).font(.headline)
            Text(verbatim: approval.browser == "safari" ? "Safari" : "Chrome")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: approval.code)
                .font(.system(size: 36, weight: .semibold, design: .monospaced))
                .tracking(8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            Text("companion.pairing.scope")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("companion.pairing.expires")
                Text(approval.expiresAt, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if store.approvalFailed {
                Text("companion.pairing.saveFailed")
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            }
            HStack {
                Spacer()
                Button("companion.pairing.reject") { store.reject(requestID: approval.id) }
                    .keyboardShortcut(.cancelAction)
                Button("companion.pairing.approve") { store.approve(requestID: approval.id) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.approvalFailed)
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
                Text(verbatim: device.browser == "safari" ? "Safari" : "Chrome")
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
