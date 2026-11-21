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
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var draft = DiagnosticReportDraft()
    @State private var evidence: DiagnosticReportEvidence = .loading
    @State private var environment: DiagnosticEnvironment?
    @State private var evidenceRevision = 0
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var exportError: String?
    @State private var showsModules = false
    @State private var hoveredModule: DiagnosticReportDraft.Module?
    @FocusState private var focusedModule: DiagnosticReportDraft.Module?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                descriptionInput
                contextFields
                evidenceSection
                contentsSummary
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .font(scale.font(.body))
        .background(Color.fromHex6(colorScheme == .dark ? 0x1C1C1E : 0xF5F5F7))
        // 高度由所有正文的实际布局决定；切换自定时间、字号或译文时随内容调整，不创建整页滚动。
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
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
            showsModules = false
            hoveredModule = nil
            focusedModule = nil
        }
        .alert("diagnostics.export.failed.title", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("general.ok") { exportError = nil }
        } message: {
            Text(verbatim: exportError ?? "")
        }
    }

    /// 诊断线索是临时表单，不是 Markdown 编辑器；输入与提示共用界面字号，避免叠加阅读微调。
    private var descriptionInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("diagnostics.report.descriptionLabel").fontWeight(.medium)
                Text("diagnostics.report.optional").font(scale.font(.caption)).foregroundStyle(.secondary)
            }
            // 原生 placeholder 与输入文字共享首行布局，不再用独立 Text 猜测 NSTextView 内边距。
            TextField("diagnostics.report.placeholder", text: $draft.description, axis: .vertical)
                .textFieldStyle(.plain)
                .font(scale.font(.body))
                .lineLimit(4, reservesSpace: true)
                .scrollIndicators(.hidden)
                .accessibilityLabel(Text("diagnostics.report.descriptionLabel"))
                .padding(8)
                .frame(minHeight: 80, alignment: .topLeading)
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
            .font(scale.font(.caption))
            .foregroundStyle(.secondary)
        }
    }

    private var contextFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            formRow("diagnostics.report.moduleLabel") {
                Button { showsModules = true } label: {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(draft.module.titleKey))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(scale.font(.caption))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(panelBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
                    .contentShape(Rectangle())
                }
                // 用完整 Button 保持值列宽度，避免 macOS Menu 重新排版自定义标签。
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(Text("diagnostics.report.moduleLabel"))
                .accessibilityValue(Text(LocalizedStringKey(draft.module.titleKey)))
                .help(Text(LocalizedStringKey(draft.module.titleKey)))
                .popover(isPresented: $showsModules, arrowEdge: .bottom) {
                    moduleChoices.appLocaleEnvironment()
                }
            }
            formRow("settings.diagnostics.capture.time") {
                DiagnosticReportTimePicker(choice: $draft.timeChoice, date: $draft.customTime)
            }
        }
        .controlSize(.regular)
        .disabled(isExporting)
    }

    /// 原生 popover 承载整行选项；鼠标、方向键和回车共用草稿选择，长译文可换行并滚动。
    private var moduleChoices: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(DiagnosticReportDraft.Module.allCases) { module in
                    Button {
                        draft.module = module
                        showsModules = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .opacity(draft.module == module ? 1 : 0)
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(module.titleKey))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            focusedModule == module ? Color.accentColor.opacity(0.12)
                                : hoveredModule == module ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .focused($focusedModule, equals: module)
                    .accessibilityAddTraits(draft.module == module ? .isSelected : [])
                    .onHover { hoveredModule = $0 ? module : nil }
                }
            }
            .padding(6)
            .padding(.trailing, 12)
        }
        .frame(width: 300, height: 330)
        .scrollIndicators(.hidden)
        .font(scale.font(.body))
        .onAppear { focusedModule = draft.module }
        .onKeyPress(.upArrow) { moveModuleFocus(-1); return .handled }
        .onKeyPress(.downArrow) { moveModuleFocus(1); return .handled }
        .onKeyPress(.return) {
            if let focusedModule { draft.module = focusedModule }
            showsModules = false
            return .handled
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hoveredModule)
    }

    /// 翻动焦点不立即提交选项，回车确认后才关闭列表。
    private func moveModuleFocus(_ offset: Int) {
        let modules = DiagnosticReportDraft.Module.allCases
        guard let index = modules.firstIndex(of: focusedModule ?? draft.module),
              modules.indices.contains(index + offset) else { return }
        focusedModule = modules[index + offset]
    }

    /// 固定标签列、伸展控件列；避免 LabeledContent 在非 Form 容器里按固有宽度居中。
    private func formRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .frame(width: 112, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelBackground: Color {
        Color.fromHex6(colorScheme == .dark ? 0x2C2C2E : 0xFFFFFF)
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider().padding(.horizontal, 12)
                HStack(spacing: 12) {
                    Text("diagnostics.report.logs")
                    Spacer(minLength: 8)
                    evidenceStatus
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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
            .font(scale.font(.caption))
            .foregroundStyle(.secondary)
            if let exportedURL {
                HStack {
                    Text("diagnostics.report.saved").font(scale.font(.caption)).foregroundStyle(.secondary)
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

    /// 导出前直接展示资料边界；紧凑的两列说明随译文换行，窗口随实际高度适配。
    private var contentsSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.diagnostics.layout.contents.title").fontWeight(.semibold)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow(alignment: .top) {
                    Text("settings.diagnostics.layout.contents.included")
                        .font(scale.font(.captionStrong))
                        .fixedSize()
                    Text("settings.diagnostics.layout.contents.includedDescription")
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow(alignment: .top) {
                    Text("settings.diagnostics.layout.contents.excluded")
                        .font(scale.font(.captionStrong))
                        .fixedSize()
                    Text("settings.diagnostics.layout.contents.excludedDescription")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(scale.font(.caption))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        // 长译文或较大字号时让说明单独占一行，保持操作按钮完整且始终靠右。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                footerStatus.fixedSize()
                Spacer(minLength: 8)
                footerActions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                footerStatus.fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    footerActions
                }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footerStatus: some View {
        HStack(spacing: 8) {
            if isExporting {
                ProgressView().controlSize(.small)
                Text("settings.diagnostics.export.running")
            } else {
                Label("diagnostics.report.localOnly", systemImage: "lock")
            }
        }
        .font(scale.font(.caption))
        .foregroundStyle(.secondary)
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
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
