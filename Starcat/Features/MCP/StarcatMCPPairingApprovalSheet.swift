//
//  StarcatMCPPairingApprovalSheet.swift
//  Starcat
//
//  外部 CLI 兑换一次性邀请时的设备确认 sheet。
//  用户看到设备名、平台与 CLI 版本后才能签发长期设备凭据。
//

import SwiftUI

struct StarcatMCPPairingApprovalSheet: View {
    let approval: StarcatMCPPairingApproval
    let approve: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.mcp.pairing.sheet.title")
                        .font(.title3.weight(.semibold))
                    Text("settings.mcp.pairing.sheet.help")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                SheetCloseButton(action: reject)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                pairingRow("settings.mcp.pairing.sheet.device", value: approval.deviceName)
                pairingRow("settings.mcp.pairing.sheet.platform", value: "\(approval.platform) / \(approval.architecture)")
                pairingRow("settings.mcp.pairing.sheet.cliVersion", value: approval.cliVersion)
            }

            Label("settings.mcp.pairing.sheet.security", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("common.cancel", action: reject)
                    .keyboardShortcut(.cancelAction)
                Button("settings.mcp.pairing.sheet.approve", action: approve)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private func pairingRow(_ title: LocalizedStringKey, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private struct StarcatMCPPairingApprovalPresenter: ViewModifier {
    let store: StarcatMCPDeviceStore

    func body(content: Content) -> some View {
        @Bindable var store = store
        content.sheet(
            isPresented: Binding(
                get: { store.pendingApproval != nil },
                set: { isPresented in
                    if !isPresented, store.pendingApproval != nil {
                        store.rejectPendingPairing()
                    }
                }
            )
        ) {
            if let approval = store.pendingApproval {
                StarcatMCPPairingApprovalSheet(
                    approval: approval,
                    approve: { store.approvePendingPairing() },
                    reject: { store.rejectPendingPairing() }
                )
                .interactiveDismissDisabled()
            }
        }
    }
}

extension View {
    func starcatMCPPairingApprovalPresenter(store: StarcatMCPDeviceStore) -> some View {
        modifier(StarcatMCPPairingApprovalPresenter(store: store))
    }
}
