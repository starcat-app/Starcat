//
//  MCPSettingsView.swift
//  Starcat
//
//  MCP Service 设置页。
//
//  本页只负责展示与触发本机 service 生命周期；真实权限判断在 `EntitlementGate`，
//  HTTP 请求层也会逐次校验 Pro + Bearer token，避免 UI 状态成为安全边界。
//

import AppKit
import SwiftUI

struct MCPSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        @Bindable var settings = settings

        return Form {
            Section("settings.mcp.section.service") {
                Toggle(isOn: Binding(
                    get: { settings.mcpServiceEnabled },
                    set: { enabled in
                        settings.mcpServiceEnabled = enabled
                        dependencies.mcpService.refreshForCurrentSettings()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.enabled.title")
                        Text("settings.mcp.enabled.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Stepper(value: $settings.mcpServicePort, in: 1024...65535, step: 1) {
                    LabeledContent("settings.mcp.port") {
                        Text("\(settings.mcpServicePort)")
                            .monospacedDigit()
                    }
                }
                .onChange(of: settings.mcpServicePort) { _, _ in
                    dependencies.mcpService.refreshForCurrentSettings()
                }

                Toggle(isOn: $settings.mcpExposePrivateNotes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.privateNotes.title")
                        Text("settings.mcp.privateNotes.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("settings.mcp.section.writes") {
                Toggle(isOn: $settings.mcpAllowLocalWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.localWrites.title")
                        Text("settings.mcp.localWrites.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.mcpAllowBatchWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.batchWrites.title")
                        Text("settings.mcp.batchWrites.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.mcpAllowLocalWrites)

                Toggle(isOn: $settings.mcpAllowDestructiveWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.destructiveWrites.title")
                        Text("settings.mcp.destructiveWrites.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.mcpAllowLocalWrites)
            }

            Section("settings.mcp.section.connection") {
                LabeledContent("settings.mcp.status") {
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }

                LabeledContent("settings.mcp.endpoint") {
                    Text(dependencies.mcpService.endpointURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                SecureTokenRow(token: dependencies.mcpService.bearerToken)

                HStack {
                    Button("settings.mcp.copyConfig") {
                        copy(dependencies.mcpService.clientConfigSnippet)
                    }
                    .focusEffectDisabled()

                    Button("settings.mcp.rotateToken") {
                        dependencies.mcpService.rotateToken()
                    }
                    .focusEffectDisabled()
                }
            }

            Section {
                Text("settings.mcp.proOnly.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            dependencies.mcpService.refreshForCurrentSettings()
        }
    }

    private var statusText: LocalizedStringKey {
        switch dependencies.mcpService.state {
        case .stopped:
            return "settings.mcp.status.stopped"
        case .running:
            return "settings.mcp.status.running"
        case .failed:
            return "settings.mcp.status.failed"
        }
    }

    private var statusColor: Color {
        switch dependencies.mcpService.state {
        case .running:
            return .green
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct SecureTokenRow: View {
    let token: String
    @State private var isRevealed = false

    var body: some View {
        LabeledContent("settings.mcp.token") {
            HStack(spacing: 8) {
                Text(isRevealed ? token : String(repeating: "•", count: 24))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button(isRevealed ? "settings.mcp.token.hide" : "settings.mcp.token.reveal") {
                    isRevealed.toggle()
                }
                .focusEffectDisabled()
            }
        }
    }
}
