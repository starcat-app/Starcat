//
//  DiagnosticReportWindow.swift
//  Starcat
//
//  独立原生诊断报告窗口：补充可选线索、查看真实采集结果并导出到本机。
//  不改变严重故障准入，不上传资料，不启动业务探测或复现录制。
//

import AppKit
import SwiftUI

/// 单例 Window Scene 的内容；标题栏和交通灯交给 macOS，不把表单塞回设置页。
struct DiagnosticReportWindow: View {
    static let sceneID = "diagnostic-report"

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var draft = DiagnosticReportDraft()
    @State private var evidence: DiagnosticReportEvidence = .loading
    @State private var environment: DiagnosticEnvironment?
    @State private var evidenceRevision = 0
    @State private var isContentsExpanded = false
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("diagnostics.report.introduction")
                        .foregroundStyle(.secondary)
                    descriptionInput
                    contextFields
                    Divider()
                    evidenceSection
                    contentsDisclosure
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .font(.body)
        .background(Color.fromHex6(colorScheme == .dark ? 0x1C1C1E : 0xF5F5F7))
        .frame(minWidth: 620, minHeight: 620)
        .navigationTitle(String.l10n("diagnostics.report.title"))
        .task(id: evidenceRevision) { await loadEvidence() }
        .onReceive(NotificationCenter.default.publisher(for: .diagnosticIssuesDidChange)) { _ in
            evidenceRevision += 1
        }
        .onChange(of: draft) { _, _ in exportedURL = nil }
        .onDisappear {
            // 关闭即丢弃临时线索；再次打开不能带入上一次报告的正文或保存结果。
            draft = DiagnosticReportDraft()
            exportedURL = nil
            evidence = .loading
            environment = nil
            exportError = nil
            isContentsExpanded = false
        }
        .alert("diagnostics.export.failed.title", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("general.ok") { exportError = nil }
        } message: {
            Text(verbatim: exportError ?? "")
        }
    }

    /// 16 号内容字体只作用于编辑器与占位提示，外部标签保持普通表单字号。
    private var descriptionInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("diagnostics.report.descriptionLabel").fontWeight(.medium)
                Text("diagnostics.report.optional").font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if draft.description.isEmpty {
                    Text("diagnostics.report.placeholder")
                        .starcatMarkdownBodyFont()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $draft.description)
                    .starcatMarkdownBodyFont()
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(Text("diagnostics.report.descriptionLabel"))
            }
            .padding(6)
            .frame(height: 112)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .disabled(isExporting)
            .onChange(of: draft.description) { _, value in
                if value.count > DiagnosticReportDraft.descriptionLimit {
                    draft.description = String(value.prefix(DiagnosticReportDraft.descriptionLimit))
                }
            }
            HStack(alignment: .top) {
                Text("diagnostics.report.privacyHint")
                Spacer(minLength: 8)
                Text(verbatim: "\(draft.description.count.formatted(.number.locale(locale))) / 2000")
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var contextFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            formRow("diagnostics.report.moduleLabel") {
                Menu {
                    Picker("diagnostics.report.moduleLabel", selection: $draft.module) {
                        ForEach(DiagnosticReportDraft.Module.allCases) { module in
                            Text(LocalizedStringKey(module.titleKey)).tag(module)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(draft.module.titleKey))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(panelBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("diagnostics.report.moduleLabel"))
                .accessibilityValue(Text(LocalizedStringKey(draft.module.titleKey)))
            }
            formRow("settings.diagnostics.capture.time") {
                DiagnosticReportTimePicker(choice: $draft.timeChoice, date: $draft.customTime)
            }
        }
        .controlSize(.regular)
        .disabled(isExporting)
    }

    /// 固定标签列、伸展控件列；避免 LabeledContent 在非 Form 容器里按固有宽度居中。
    private func formRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .frame(width: 112, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelBackground: Color {
        Color.fromHex6(colorScheme == .dark ? 0x2C2C2E : 0xFFFFFF)
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("diagnostics.report.dataTitle").fontWeight(.semibold)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("diagnostics.report.environment")
                    Spacer(minLength: 8)
                    Label {
                        Text(LocalizedStringKey(environment == nil ? "diagnostics.report.collecting" : "diagnostics.report.collected"))
                    } icon: {
                        Image(systemName: environment == nil ? "ellipsis" : "checkmark.circle")
                            .foregroundStyle(environment == nil ? Color.secondary : Color.green)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(12)
                Divider().padding(.horizontal, 12)
                HStack(spacing: 12) {
                    Text("diagnostics.report.logs")
                    Spacer(minLength: 8)
                    evidenceStatus
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }
            Label {
                evidenceExplanation
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let exportedURL {
                HStack {
                    Text("diagnostics.report.saved").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("settings.storage.revealInFinder") {
                        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                    }
                    .buttonStyle(.bordered)
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: evidence)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: exportedURL)
    }

    @ViewBuilder
    private var evidenceStatus: some View {
        switch evidence {
        case .loading: Text("diagnostics.report.collecting")
        case .unavailable: Text("diagnostics.report.unavailable")
        case .available(let count, _):
            Text(verbatim: String(format: String.l10n("diagnostics.report.eventCount"), locale: locale, Int64(count)))
        }
    }

    @ViewBuilder
    private var evidenceExplanation: some View {
        switch evidence {
        case .loading: Text("diagnostics.report.collecting")
        case .unavailable, .available(_, true): Text("diagnostics.report.incomplete")
        case .available(0, false): Text("diagnostics.report.empty")
        case .available: Text("diagnostics.report.ready")
        }
    }

    private var contentsDisclosure: some View {
        DisclosureGroup(isExpanded: $isContentsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.diagnostics.layout.contents.included").fontWeight(.semibold)
                Text("settings.diagnostics.layout.contents.includedDescription")
                Text("settings.diagnostics.layout.contents.excluded").fontWeight(.semibold)
                Text("settings.diagnostics.layout.contents.excludedDescription")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        } label: {
            Text("diagnostics.report.contents").font(.caption)
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle(
            accessibilityLabel: Text("diagnostics.report.contents"),
            accessibilityHint: Text("settings.diagnostics.layout.contents.summary")
        ))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isExporting {
                ProgressView().controlSize(.small)
                Text("settings.diagnostics.export.running").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("diagnostics.report.localOnly", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("general.cancel") { dismissWindow(id: Self.sceneID) }
                .keyboardShortcut(.cancelAction)
                .disabled(isExporting)
            Button("settings.diagnostics.layout.export.button") {
                Task { await exportReport() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isExporting)
        }
        .controlSize(.regular)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    /// 快照和解码在后台完成；关闭窗口或更新快照后，旧任务不能回写当前预览。
    @MainActor
    private func loadEvidence() async {
        environment = DiagnosticEnvironment.current()
        let since = Date().addingTimeInterval(-86400)
        let snapshot = await DiagnosticDeadline.capture { await DiagnosticLogStore.shared.snapshot() }
        let result = await Task.detached(priority: .utility) {
            DiagnosticReportEvidence.read(snapshot, since: since)
        }.value
        guard !Task.isCancelled else { return }
        evidence = result
    }

    /// 保存面板取消后保留草稿；成功只报告本机保存，不忽略提醒或宣称故障已恢复。
    @MainActor
    private func exportReport() async {
        guard !isExporting else { return }
        isExporting = true
        exportedURL = nil
        defer { isExporting = false }
        switch await DiagnosticBundleExporter.exportFromPanel(settings: settings, options: draft.exportOptions()) {
        case .exported(let url): exportedURL = url
        case .cancelled: break
        case .failed(let message): exportError = message
        }
    }
}
