//
//  DiagnosticsSettingsTab.swift
//  Starcat
//
//  诊断与支持设置：本地诊断导出、连接配置入口和日志说明。
//  只重组呈现与导航，不主动发起连接测试，也不改变诊断包内容与问题确认流程。
//

import SwiftUI

/// 使用与其他设置页一致的原生分组表单；配置检查仍由各自设置页负责。
struct DiagnosticsSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies

    @State private var isExporting = false
    @State private var lastExportMessage: String?
    @State private var exportError: String?
    @State private var isReportContentsExpanded = false
    @State private var isLogGuidePresented = false

    var body: some View {
        Form {
            SettingsPageIntroduction(
                title: "settings.navigation.item.diagnosticsSupport",
                systemImage: BusinessIcon.Symbol.diagnostics.rawValue,
                description: "settings.diagnostics.layout.introduction.description",
                context: "settings.diagnostics.layout.introduction.context"
            )
            reportSection
            connectionsSection
            supportSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isLogGuidePresented) {
            DiagnosticLogGuideSheet()
                .appLocaleEnvironment()
        }
        .alert(
            "diagnostics.export.failed.title",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("general.ok") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var reportSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text("settings.diagnostics.layout.export.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.diagnostics.layout.export.description"))
                    Spacer(minLength: 8)
                    Button {
                        Task { await exportDiagnostics() }
                    } label: {
                        Text("settings.diagnostics.layout.export.button")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isExporting)
                    .fixedSize(horizontal: true, vertical: false)
                }
                if isExporting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("settings.diagnostics.export.running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let lastExportMessage {
                    Text(verbatim: lastExportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            DisclosureGroup(isExpanded: $isReportContentsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    explanation(
                        "settings.diagnostics.layout.contents.included",
                        description: "settings.diagnostics.layout.contents.includedDescription"
                    )
                    Divider()
                    explanation(
                        "settings.diagnostics.layout.contents.excluded",
                        description: "settings.diagnostics.layout.contents.excludedDescription"
                    )
                }
            } label: {
                explanation(
                    "settings.diagnostics.layout.contents.title",
                    description: "settings.diagnostics.layout.contents.summary"
                )
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.diagnostics.layout.contents.title"),
                accessibilityHint: Text("settings.diagnostics.layout.contents.summary")
            ))
        } header: {
            SettingsSectionHeader("settings.diagnostics.layout.report.title", systemImage: "doc.text")
        }
    }

    private var connectionsSection: some View {
        Section {
            LabeledContent {
                // 登录态来自现有会话，不把缓存账号信息误报成刚刚通过的网络连接测试。
                if let login = dependencies.authSession.state.user?.login {
                    HStack(spacing: 8) {
                        Label("search.github.signedIn", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text(verbatim: login)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(login)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("settings.privacy.github.account.signedOut")
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text(verbatim: "GitHub")
            }
            navigationRow(
                "settings.diagnostics.layout.connections.backend",
                action: "settings.diagnostics.layout.connections.services",
                target: "services"
            )
            navigationRow(
                "settings.models.title",
                action: "settings.diagnostics.layout.connections.models",
                target: "ai.models"
            )
            navigationRow(
                "settings.navigation.item.webSearch",
                action: "settings.diagnostics.layout.connections.search",
                target: "ai.externalSearch"
            )
            LabeledContent {
                HStack(spacing: 8) {
                    navigationButton("settings.mcp.title", target: "mcp")
                    navigationButton("settings.navigation.item.browserExtensions", target: "integrations")
                }
            } label: {
                Text("settings.diagnostics.layout.connections.extensions")
            }
        } header: {
            SettingsSectionHeader("settings.diagnostics.layout.connections.title", systemImage: "network")
        }
    }

    private var supportSection: some View {
        Section {
            HStack(alignment: .center, spacing: 8) {
                explanation(
                    "settings.diagnostics.layout.logs.title",
                    description: "settings.diagnostics.layout.logs.description"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    isLogGuidePresented = true
                } label: {
                    Text("settings.diagnostics.layout.logs.open")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
            }
            navigationRow(
                "settings.diagnostics.layout.preferences.title",
                action: "settings.navigation.item.privacyPermissions",
                target: "diagnostics.privacy"
            )
        } header: {
            SettingsSectionHeader("settings.diagnostics.layout.support.title", systemImage: "lifepreserver")
        }
    }

    /// 标题与说明保持统一间距，长语言自然增高，不改变右侧原生控件的大小。
    private func explanation(_ title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func navigationRow(
        _ title: LocalizedStringKey,
        action: LocalizedStringKey,
        target: String
    ) -> some View {
        LabeledContent {
            navigationButton(action, target: target)
        } label: {
            Text(title)
        }
    }

    /// 沿用设置窗口的统一路由，保留返回历史及目标页面原有的定位逻辑。
    private func navigationButton(_ title: LocalizedStringKey, target: String) -> some View {
        Button {
            NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: target)
        } label: {
            Text(title)
                .lineLimit(1)
                .help(Text(title))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .fixedSize(horizontal: true, vertical: false)
    }

    @MainActor
    private func exportDiagnostics() async {
        isExporting = true
        defer { isExporting = false }

        switch await DiagnosticBundleExporter.exportFromPanel(settings: settings) {
        case .exported(_):
            // 导出器成功后已经标记诊断问题为已处理；这里用固定反馈同步告知状态已重置。
            lastExportMessage = String.l10n("settings.diagnostics.export.successMessage")
        case .cancelled:
            break
        case .failed(let message):
            exportError = message
        }
    }
}
