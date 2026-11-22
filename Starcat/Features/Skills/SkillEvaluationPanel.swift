//
//  SkillEvaluationPanel.swift
//  Starcat
//
//  仓库详情与本机库共用的评估会话。面板只保留 UI 状态，关闭时停止观察，
//  后台评估与报告的生命周期仍由应用级服务管理。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 入口提供稳定目标和供确认页辨认的名称；路径和实际输入由评估服务解析。
struct SkillEvaluationPanelItem: Identifiable {
    let target: SkillEvaluationTarget
    let name: String
    var source: String? = nil

    var id: SkillEvaluationSubject { target.identity }
}

/// 保留原选区与上次任务的联系，筛选后的批次也能在关窗完成后找回。
struct SkillEvaluationPanelTaskLink {
    struct AIConfiguration {
        let providerName: String
        let model: SkillEvaluationSelection
    }

    let id: String
    let mode: SkillEvaluationMode
    let selection: Set<SkillEvaluationSubject>
    let runSubjects: Set<SkillEvaluationSubject>
    let configuration: AIConfiguration?
}

/// 使用固定的入口选择，避免其他窗口改变选择时扩大已经展示的发送范围。
struct SkillEvaluationPanel: View {
    let items: [SkillEvaluationPanelItem]
    let service: SkillEvaluationService
    let rememberedTask: Binding<SkillEvaluationPanelTaskLink?>
    let close: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var mode: SkillEvaluationMode = .quick
    @State private var filter: SkillEvaluationPanelStatus = .all
    @State private var records: [SkillEvaluationMode: [SkillEvaluationCached]] = [:]
    @State private var loadFailed = false
    @State private var reloadRevision = 0
    @State private var selectedReportID: UUID?
    @State private var confirmation: Confirmation?
    @State private var providerID: String?
    @State private var chatName: String?
    @State private var embeddingName: String?
    @State private var hasRestoredTask = false
    @State private var observedTask: SkillEvaluationPanelTaskLink?
    @State private var taskID: String?
    @State private var taskStatus: TaskStatus?
    @State private var showsRunResults = false
    @State private var failures: [String] = []
    @State private var showsCancelConfirmation = false
    @State private var actionError: ActionError?
    @State private var filePanel: NSSavePanel?

    private struct Confirmation {
        let mode: SkillEvaluationMode
        let configuration: SkillEvaluationPanelTaskLink.AIConfiguration
        let items: [SkillEvaluationPanelItem]
    }

    private struct ReportQuery: Equatable {
        let mode: SkillEvaluationMode
        let serviceRevision: UInt64
        let reloadRevision: Int
    }

    private enum TaskStatus: Equatable {
        case working, cancelling, cancelled, failed, completed

        var title: LocalizedStringKey {
            switch self {
            case .working: "skills.evaluation.task.working"
            case .cancelling: "skills.evaluation.task.cancelling"
            case .cancelled: "skills.evaluation.task.cancelled"
            case .failed: "skills.evaluation.task.failed"
            case .completed: "skills.evaluation.task.completed"
            }
        }

        var symbol: String {
            switch self {
            case .working: "hourglass"
            case .cancelling, .cancelled: "stop.circle"
            case .failed: "exclamationmark.circle"
            case .completed: "checkmark.circle"
            }
        }
    }

    private enum ActionError {
        case service(String), tool, cancel, export

        var text: Text {
            switch self {
            case .service(let message): Text(verbatim: message)
            case .tool: Text("skills.evaluation.error.setup")
            case .cancel: Text("skills.evaluation.error.cancel")
            case .export: Text("skills.evaluation.error.export")
            }
        }
    }

    var body: some View {
        let query = ReportQuery(mode: mode, serviceRevision: service.revision, reloadRevision: reloadRevision)
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .topLeading) {
                if let confirmation {
                    ScrollView { consentContent(confirmation).padding(20) }
                        .background(canvas)
                        .detailContentTransition()
                } else if let report = selectedReport {
                    let sources = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.source.map { (item.id, $0) } })
                    ScrollView { SkillEvaluationReportDetail(cached: report, sources: sources).padding(20) }
                        .background(canvas)
                        .id(report.report.id)
                        .detailContentTransition()
                } else {
                    ScrollView { overview.padding(20) }
                        .background(canvas)
                        .id(showsRunResults)
                        .detailContentTransition()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: confirmation != nil)
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: selectedReportID)
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: showsRunResults)
            Divider()
            footer
        }
        .background(RepoSkillPanelStyle.panelColor(colorScheme))
        .task { service.refreshTool() }
        .task(id: query) {
            guard !Task.isCancelled else { return }
            if !hasRestoredTask {
                hasRestoredTask = true
                resumeExistingTask()
            }
            await loadReports(query)
        }
        .task(id: taskID) {
            if let taskID { await watchTask(taskID) }
        }
        .onChange(of: mode) { resetModeState() }
        .onChange(of: providerID) {
            chatName = nil
            embeddingName = nil
        }
        .onDisappear {
            // 原生文件面板不会随 SwiftUI 内容树释放，需要和评估面板一起关闭。
            let panel = filePanel
            filePanel = nil
            panel?.cancel(nil)
        }
        .alert("skills.evaluation.task.cancelConfirmation", isPresented: $showsCancelConfirmation) {
            Button("skills.evaluation.task.cancel", role: .destructive, action: cancelTask)
            Button("skills.evaluation.back", role: .cancel) {}
        }
        .alert("skills.evaluation.error.title", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("skills.evaluation.dismiss", role: .cancel) { actionError = nil }
        } message: {
            actionError?.text ?? Text("skills.evaluation.task.failed")
        }
    }

    private var canvas: Color {
        colorScheme == .dark ? Color.fromHex6(0x1C1C1E) : Color(nsColor: .windowBackgroundColor)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if confirmation != nil || selectedReport != nil {
                Button {
                    confirmation = nil
                    selectedReportID = nil
                } label: {
                    Label("skills.evaluation.back", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                }
                .help("skills.evaluation.back")
                .keyboardShortcut(.cancelAction)
            } else {
                Image(systemName: mode.panelSymbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Group {
                if confirmation != nil {
                    Text("skills.evaluation.consent.title")
                } else if selectedReport != nil {
                    Text("skills.evaluation.report.title")
                } else {
                    Text("skills.evaluation.title")
                }
            }
            .font(interfaceScale.font(.workspaceTitle))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            SheetCloseButton(action: close, helpKey: "skills.evaluation.dismiss")
                .accessibilityLabel(Text("skills.evaluation.dismiss"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showsRunResults {
                taskFeedback
                if taskID != nil, let observedTask {
                    subjectSection(resultItems)
                    if let configuration = observedTask.configuration {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionTitle("skills.evaluation.configuration.section")
                            configurationSummary(configuration)
                                .padding(14)
                                .skillEvaluationCard(colorScheme)
                        }
                    }
                }
            } else {
                toolSetup
                if let log = service.toolInstallLog {
                    SkillEvaluationInstallLogView(log: log)
                        .id(log.id)
                }
                controls
            }
            if (mode != .similarity || items.count >= 2) && (taskID == nil || loadFailed || records[mode]?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 8) {
                    resultsHeader
                    reportResults
                        .padding(4)
                        .skillEvaluationCard(colorScheme)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 首次使用的操作跟状态一起显示。模式和筛选留在原位，便于缺少工具时翻阅历史报告。
    private var toolSetup: some View {
        Group {
            switch service.toolState {
            case .checking:
                toolProgress("skills.evaluation.setup.checking")
            case .ready:
                EmptyView()
            case .unavailable(let issue):
                VStack(alignment: .leading, spacing: 8) {
                    Label(toolIssueTitle(issue), systemImage: "wrench.and.screwdriver")
                        .font(interfaceScale.font(.body).weight(.semibold))
                    Text("skills.evaluation.setup.location")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { setupActions(issue) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 6) { setupActions(issue) }
                    }
                    .disabled(!service.canChangeTool || filePanel != nil)
                }
            case .installing(let stage):
                VStack(alignment: .leading, spacing: 8) {
                    toolProgress(toolStageTitle(stage))
                    Button("skills.evaluation.setup.cancel", action: service.cancelToolInstall)
                }
            case .cancelling:
                toolProgress("skills.evaluation.setup.cancelling")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: service.toolState)
    }

    @ViewBuilder
    private func setupActions(_ issue: SkillEvaluationToolState.Issue) -> some View {
        Button(issue == .installFailed || issue == .installCancelled
               ? "skills.evaluation.setup.retry" : "skills.evaluation.setup.install", action: service.installTool)
            .buttonStyle(.borderedProminent)
        Button("skills.evaluation.tool.choose", action: chooseTool)
    }

    private func toolProgress(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            if !reduceMotion {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
            Text(title)
                .font(interfaceScale.font(.body))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }

    private func toolIssueTitle(_ issue: SkillEvaluationToolState.Issue) -> LocalizedStringKey {
        switch issue {
        case .missing: "skills.evaluation.setup.missing"
        case .incompatible: "skills.evaluation.setup.incompatible"
        case .installFailed: "skills.evaluation.setup.failed"
        case .installCancelled: "skills.evaluation.setup.cancelled"
        }
    }

    private func toolStageTitle(_ stage: SkillEvaluationInstaller.Stage) -> LocalizedStringKey {
        switch stage {
        case .downloading: "skills.evaluation.setup.downloading"
        case .preparingPython: "skills.evaluation.setup.preparing"
        case .installingPackage: "skills.evaluation.setup.installing"
        case .verifying: "skills.evaluation.setup.verifying"
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("skills.evaluation.configuration.section")
            VStack(alignment: .leading, spacing: 12) {
                selectionMenu("skills.evaluation.mode.title", selection: $mode) {
                    ForEach(SkillEvaluationMode.allCases, id: \.self) { option in
                        Label(option.panelTitle, systemImage: option.panelSymbol).tag(option)
                    }
                }
                Text(configurationNote)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                if mode.requiresAI && (mode != .similarity || items.count >= 2) {
                    Divider()
                    modelControls.disabled(!service.canUseTool)
                }
            }
            .padding(14)
            .skillEvaluationCard(colorScheme)
        }
        .font(interfaceScale.font(.body))
    }

    private var configurationNote: LocalizedStringKey {
        switch mode {
        case .quick: "skills.evaluation.mode.quickNote"
        case .security: "skills.evaluation.mode.securityNote"
        case .similarity where items.count < 2: "skills.evaluation.mode.similarityNote"
        default: mode.consentScope
        }
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if eligibleProfiles.isEmpty {
                Text("skills.evaluation.configuration.empty").foregroundStyle(.secondary)
            } else {
                let profile = selectedProfile
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176 * interfaceScale.multiplier), spacing: 12,
                                             alignment: .topLeading)], alignment: .leading, spacing: 8) {
                    selectionMenu("skills.evaluation.configuration.title", selection: $providerID) {
                        Text("skills.evaluation.configuration.select").tag(nil as String?)
                        ForEach(eligibleProfiles) { profile in
                            Text(verbatim: profile.displayName).tag(Optional(profile.id))
                        }
                    }
                    .help(profile?.displayName ?? "")
                    if let profile, mode.needsChat {
                        modelPicker("skills.evaluation.configuration.chat", placeholder: "skills.evaluation.configuration.chooseChat",
                                    models: enabledModels(in: profile, capability: .chat), selection: $chatName)
                    }
                    if let profile, mode.needsEmbedding {
                        modelPicker("skills.evaluation.configuration.embedding",
                                    placeholder: "skills.evaluation.configuration.chooseEmbedding",
                                    models: enabledModels(in: profile, capability: .embedding), selection: $embeddingName)
                    }
                }
                if let profile {
                    SkillEvaluationConnectionDetails(modelEndpoint: profile.baseURL)
                        .id(profile.id)
                }
            }
        }
    }

    private func modelPicker(
        _ title: LocalizedStringKey, placeholder: LocalizedStringKey,
        models: [AIModelDescriptor], selection: Binding<String?>
    ) -> some View {
        selectionMenu(title, selection: selection) {
            Text(placeholder).tag(nil as String?)
            ForEach(models) { model in Text(verbatim: model.name).tag(Optional(model.name)) }
        }
        .help(selection.wrappedValue ?? "")
    }

    private func selectionMenu<Value: Hashable, Options: View>(
        _ title: LocalizedStringKey, selection: Binding<Value>, @ViewBuilder options: () -> Options
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(interfaceScale.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker(title, selection: selection, content: options)
                .pickerStyle(.menu)
                .labelsHidden()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(interfaceScale.font(.rowTitle, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var resultsHeader: some View {
        HStack(spacing: 8) {
            sectionTitle(showsRunResults ? "skills.evaluation.report.results" : "skills.evaluation.report.comparison")
            Spacer(minLength: 0)
            if resultItems.count > 1 && taskID == nil {
                Picker("skills.evaluation.filter.title", selection: $filter) {
                    ForEach(SkillEvaluationPanelStatus.allCases, id: \.self) { status in
                        Text(status.title).tag(status)
                    }
                }
                .labelsHidden()
                .help("skills.evaluation.filter.title")
                .controlSize(.small)
                .disabled(records[mode] == nil)
            }
        }
    }

    @ViewBuilder
    private var taskFeedback: some View {
        if let taskStatus {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    if taskID != nil && !reduceMotion {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    } else {
                        Image(systemName: taskStatus.symbol)
                            .font(interfaceScale.font(.rowTitle))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        sectionTitle(taskStatus.title)
                            .contentTransition(.opacity)
                        Text(mode.panelTitle)
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                if taskID != nil {
                    Text("skills.evaluation.task.background")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                }
                if !failures.isEmpty {
                    Text("skills.evaluation.task.failures")
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(failures.indices, id: \.self) { index in
                        Text(verbatim: failures[index]).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .skillEvaluationCard(colorScheme)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: taskStatus)
        }
    }

    @ViewBuilder
    private var reportResults: some View {
        if loadFailed {
            HStack {
                Text("skills.evaluation.error.load").foregroundStyle(.secondary)
                Button("skills.evaluation.retry") { reloadRevision += 1 }
            }
            .padding(8)
        }
        if records[mode] == nil && !loadFailed {
            Text("skills.evaluation.loading")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .padding(8)
            ListLoadingSkeleton(rowCount: min(items.count, 4), rowHeight: 48)
                .transition(.opacity)
        } else if records[mode] != nil {
            let reports = reportBySubject
            let rows = taskID == nil || comparisonReport != nil ? filteredItems : filteredItems.filter { reports[$0.id] != nil }
            if rows.isEmpty {
                Text("skills.evaluation.filter.empty").foregroundStyle(.secondary).padding(8)
            } else if mode == .similarity, let comparisonReport {
                resultRow(
                    name: Text(mode.panelTitle), cached: comparisonReport, index: 0,
                    source: comparisonReport.report.names.joined(separator: " · ")
                )
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        resultRow(name: Text(verbatim: item.name), cached: reports[item.id], index: index, source: item.source)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(name: Text, cached: SkillEvaluationCached?, index: Int, source: String? = nil) -> some View {
        if let cached {
            Button {
                selectedReportID = cached.report.id
            } label: {
                HStack {
                    resultRowLabel(name: name, status: SkillEvaluationPanelStatus(cached), source: source)
                    Image(systemName: "chevron.forward")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .listRowSurface(index: index)
        } else {
            resultRowLabel(name: name, status: .notRun, source: source)
                .padding(.horizontal, 8)
                .frame(minHeight: 48)
                .listRowSurface(index: index)
                .accessibilityElement(children: .combine)
        }
    }

    private func resultRowLabel(name: Text, status: SkillEvaluationPanelStatus, source: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .similarity && status != .notRun ? "square.stack" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                name.font(interfaceScale.font(.body, weight: .semibold)).lineLimit(1)
                if let source {
                    Text(verbatim: source)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(source)
                }
            }
            Spacer(minLength: 8)
            SkillEvaluationStatusBadge(status: status)
        }
    }

    private func consentContent(_ consent: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("skills.evaluation.consent.content")
                Text(consent.mode.consentScope)
                Text("skills.evaluation.consent.notice")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .skillEvaluationCard(colorScheme)

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("skills.evaluation.configuration.section")
                VStack(alignment: .leading, spacing: 8) {
                    configurationField("skills.evaluation.mode.title", Text(consent.mode.panelTitle))
                    configurationSummary(consent.configuration)
                }
                .padding(14)
                .skillEvaluationCard(colorScheme)
            }
            subjectSection(consent.items)
        }
        .font(interfaceScale.font(.body))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configurationSummary(_ configuration: SkillEvaluationPanelTaskLink.AIConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configurationField("skills.evaluation.configuration.title", Text(verbatim: configuration.providerName))
            if !configuration.model.chat.isEmpty {
                configurationField("skills.evaluation.configuration.chat",
                                   Text(verbatim: configuration.model.chat).font(interfaceScale.font(.code)))
            }
            if let embedding = configuration.model.embedding {
                configurationField("skills.evaluation.configuration.embedding",
                                   Text(verbatim: embedding).font(interfaceScale.font(.code)))
            }
            Divider()
            SkillEvaluationConnectionDetails(modelEndpoint: configuration.model.endpoint)
        }
        .font(interfaceScale.font(.body))
    }

    private func subjectSection(_ includedItems: [SkillEvaluationPanelItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("skills.evaluation.report.comparison")
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(includedItems.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.name).font(interfaceScale.font(.body, weight: .semibold))
                            if let source = item.source {
                                Text(verbatim: source)
                                    .font(interfaceScale.font(.code))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).help(source)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .listRowSurface(index: index)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(4)
            .skillEvaluationCard(colorScheme)
        }
    }

    private func configurationField(_ label: LocalizedStringKey, _ value: Text) -> some View {
        SkillEvaluationDetailField(label: Text(label).foregroundStyle(.secondary), value: value)
    }

    private var footer: some View {
        HStack {
            if let confirmation {
                Spacer()
                Button("skills.evaluation.consent.send") {
                    self.confirmation = nil
                    start(items: confirmation.items, mode: confirmation.mode, confirmedConfiguration: confirmation.configuration)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!service.canUseTool || filePanel != nil)
            } else if let report = selectedReport {
                Spacer()
                Button("skills.evaluation.report.export") { export([report]) }
            } else {
                if service.toolReady {
                    // 就绪后手选是次要操作。使用图标为窄窗的评估和取消按钮保留空间。
                    Button(action: chooseTool) {
                        Label("skills.evaluation.tool.choose", systemImage: "folder")
                            .labelStyle(.iconOnly)
                    }
                    .help("skills.evaluation.tool.choose")
                    .disabled(!service.canChangeTool || filePanel != nil)
                }
                Spacer(minLength: 8)
                Button {
                    export(visibleReports)
                } label: {
                    Label("skills.evaluation.report.exportAll", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .help("skills.evaluation.report.exportAll")
                .disabled(visibleReports.isEmpty || filePanel != nil)

                if taskID != nil {
                    Button("skills.evaluation.task.cancel") { showsCancelConfirmation = true }
                        .disabled(taskStatus == .cancelling)
                } else if showsRunResults {
                    Button("skills.evaluation.configuration.section") { showsRunResults = false }
                } else {
                    Button("skills.evaluation.action", action: requestEvaluation)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var comparisonReport: SkillEvaluationCached? {
        mode == .similarity ? records[mode]?.first : nil
    }

    private var reportBySubject: [SkillEvaluationSubject: SkillEvaluationCached] {
        guard mode != .similarity else { return [:] }
        return Dictionary((records[mode] ?? []).compactMap { cached in
            cached.report.subjects.first.map { ($0, cached) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private var resultItems: [SkillEvaluationPanelItem] {
        guard showsRunResults, let observedTask else { return items }
        return items.filter { observedTask.runSubjects.contains($0.id) }
    }

    private var filteredItems: [SkillEvaluationPanelItem] {
        guard filter != .all else { return resultItems }
        let reports = reportBySubject
        let comparison = comparisonReport
        return resultItems.filter { SkillEvaluationPanelStatus(comparison ?? reports[$0.id]) == filter }
    }

    private var visibleReports: [SkillEvaluationCached] {
        guard !filteredItems.isEmpty else { return [] }
        if let comparisonReport { return [comparisonReport] }
        let reports = reportBySubject
        return filteredItems.compactMap { reports[$0.id] }
    }

    private var selectedReport: SkillEvaluationCached? {
        records[mode]?.first { $0.report.id == selectedReportID }
    }

    private var eligibleProfiles: [AIProviderProfile] {
        service.profiles().filter { profile in
            (!mode.needsChat || !enabledModels(in: profile, capability: .chat).isEmpty)
                && (!mode.needsEmbedding || !enabledModels(in: profile, capability: .embedding).isEmpty)
        }
    }

    private var selectedProfile: AIProviderProfile? {
        eligibleProfiles.first { $0.id == providerID }
    }

    private var selectedModel: SkillEvaluationSelection? {
        guard let profile = selectedProfile else { return nil }
        let chat = enabledModels(in: profile, capability: .chat).first { $0.name == chatName }?.name
        let embedding = enabledModels(in: profile, capability: .embedding).first { $0.name == embeddingName }?.name
        guard (!mode.needsChat || chat != nil), (!mode.needsEmbedding || embedding != nil) else { return nil }
        return SkillEvaluationSelection(providerID: profile.id, endpoint: profile.baseURL, chat: mode.needsChat ? chat ?? "" : "",
                                        embedding: mode.needsEmbedding ? embedding : nil)
    }

    private func enabledModels(in profile: AIProviderProfile, capability: AIModelCapability) -> [AIModelDescriptor] {
        profile.models.filter { $0.isEnabled && ($0.capability == capability || $0.capability == .unknown) }
    }

    private var canStart: Bool {
        service.canUseTool && filePanel == nil && !loadFailed && records[mode] != nil && !filteredItems.isEmpty
            && (mode != .similarity || filteredItems.count >= 2)
            && (!mode.requiresAI || selectedModel != nil)
    }

    private func resetModeState() {
        filter = .all
        providerID = nil
        chatName = nil
        embeddingName = nil
        selectedReportID = nil
        if taskID == nil, observedTask?.mode != mode {
            observedTask = nil
            taskStatus = nil
            failures = []
            showsRunResults = false
        }
        loadFailed = false
    }

    /// 正在运行的精确任务优先。上次从本面板发起的任务也可以回读终态和逐项失败。
    private func resumeExistingTask() {
        let targets = items.map(\.target)
        guard taskID == nil else { return }
        for option in SkillEvaluationMode.allCases where option != .similarity || targets.count >= 2 {
            guard let activeID = service.activeTask(targets: targets, mode: option) else { continue }
            mode = option
            observeTask(activeID, mode: option)
            return
        }
        guard let link = rememberedTask.wrappedValue, link.selection == Set(items.map(\.id)) else { return }
        guard service.matchesTask(id: link.id, within: targets, mode: link.mode) else {
            rememberedTask.wrappedValue = nil
            return
        }
        mode = link.mode
        observeTask(link.id, mode: link.mode, runSubjects: link.runSubjects)
    }

    /// 服务 revision 同时覆盖别处触发的评估。新的缓存批次可用前继续显示本模式的上一份报告。
    private func loadReports(_ query: ReportQuery) async {
        guard !Task.isCancelled, mode == query.mode else { return }
        guard query.mode != .similarity || items.count >= 2 else { return }
        let targets = items.map(\.target)
        attachIfRunning(targets: targets, mode: query.mode)
        // 同模式刷新优先保留已接回的筛选任务，完整选择的旧记录不能覆盖其逐项状态。
        if taskID == nil, observedTask?.mode != query.mode,
           let id = service.latestTask(targets: targets, mode: query.mode) {
            observeTask(id, mode: query.mode)
        }
        do {
            let loaded = try await service.latest(targets: targets, mode: query.mode)
            guard !Task.isCancelled, mode == query.mode else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.18)) {
                records[query.mode] = loaded
                loadFailed = false
            }
            if selectedReport == nil { selectedReportID = nil }
        } catch {
            guard !Task.isCancelled, mode == query.mode else { return }
            loadFailed = true
        }
    }

    private func requestEvaluation() {
        guard canStart else { return }
        let selected = filteredItems
        if mode.requiresAI {
            guard let selectedModel, let profile = selectedProfile else { return }
            confirmation = Confirmation(mode: mode, configuration: .init(providerName: profile.displayName, model: selectedModel),
                                        items: selected)
        } else {
            start(items: selected, mode: mode)
        }
    }

    private func start(
        items: [SkillEvaluationPanelItem], mode: SkillEvaluationMode,
        confirmedConfiguration: SkillEvaluationPanelTaskLink.AIConfiguration? = nil
    ) {
        guard taskID == nil, service.canUseTool else { return }
        let targets = items.map(\.target)
        attachIfRunning(targets: targets, mode: mode)
        guard taskID == nil else { return }
        do {
            let id = try service.start(targets: targets, mode: mode, model: confirmedConfiguration?.model,
                                       consent: confirmedConfiguration != nil)
            observeTask(id, mode: mode, runSubjects: Set(items.map(\.id)), configuration: confirmedConfiguration)
        } catch {
            actionError = serviceError(error, fallback: .service(String.l10n("skills.evaluation.task.failed")))
        }
    }

    private func attachIfRunning(targets: [SkillEvaluationTarget], mode: SkillEvaluationMode) {
        guard taskID == nil, let activeID = service.activeTask(targets: targets, mode: mode) else { return }
        observeTask(activeID, mode: mode, runSubjects: Set(targets.map(\.identity)))
    }

    /// 只显示当前任务确认时的配置。另一个入口发起的任务可能没有可用的面板快照。
    private func observeTask(
        _ id: String, mode: SkillEvaluationMode, runSubjects: Set<SkillEvaluationSubject>? = nil,
        configuration: SkillEvaluationPanelTaskLink.AIConfiguration? = nil
    ) {
        guard observedTask?.id != id else { return }
        let selection = Set(items.map(\.id))
        let previous = rememberedTask.wrappedValue
        let rememberedConfiguration = previous?.id == id ? previous?.configuration : nil
        let link = SkillEvaluationPanelTaskLink(id: id, mode: mode, selection: selection, runSubjects: runSubjects ?? selection,
                                               configuration: configuration ?? rememberedConfiguration)
        observedTask = link
        failures = []
        taskID = id
        updateTaskStatus(id)
        showsRunResults = true
        filter = .all
        if taskID != nil {
            // 正在运行的任务已有冻结的输入，回接只观察，关闭可能已打开的发送确认。
            confirmation = nil
            rememberedTask.wrappedValue = link
        }
    }

    /// 轮询只更新展示。终态须由公共任务句柄确认，不能把“已请求取消”当成“已取消”。
    private func watchTask(_ id: String) async {
        while !Task.isCancelled, taskID == id {
            updateTaskStatus(id)
            if taskID == nil {
                reloadRevision += 1
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    private func updateTaskStatus(_ id: String) {
        switch try? service.taskState(id: id) {
        case "queued", "running":
            taskStatus = .working
            return
        case "cancelling":
            taskStatus = .cancelling
            return
        case "succeeded": taskStatus = .completed
        case "cancelled": taskStatus = .cancelled
        default: taskStatus = .failed
        }
        taskID = nil
        failures = (try? service.taskFailures(id: id)) ?? []
    }

    private func cancelTask() {
        guard let taskID else { return }
        do {
            try service.cancel(id: taskID)
            // 立即回读，避免已自然结束的任务短暂回到“正在取消”。
            if try service.taskState(id: taskID) == "cancelling" { taskStatus = .cancelling }
        } catch {
            actionError = serviceError(error, fallback: .cancel)
        }
    }

    private func chooseTool() {
        guard filePanel == nil, service.canChangeTool else { return }
        Task {
            do {
                try await service.chooseExecutable { await pickTool() }
            } catch let failure as SkillEvaluationFailure where failure.code == "busy" {
                actionError = .service(failure.localizedDescription)
            } catch {
                actionError = .tool
            }
        }
    }

    /// 原生选择器和验证期间都保留共享服务的手选状态。关窗后忽略已失去归属的选择。
    private func pickTool() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = String.l10n("skills.evaluation.error.setup")
        filePanel = panel
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard filePanel === panel else { return nil }
        filePanel = nil
        return response == .OK ? panel.url : nil
    }

    private func export(_ reports: [SkillEvaluationCached]) {
        guard !reports.isEmpty, filePanel == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String.l10n("skills.evaluation.report.filename") + ".json"
        panel.canCreateDirectories = true
        filePanel = panel
        panel.begin { response in
            guard filePanel === panel else { return }
            filePanel = nil
            guard response == .OK, let url = panel.url else { return }
            do { try SkillEvaluationService.export(reports).write(to: url, options: .atomic) }
            catch { actionError = .export }
        }
    }

    /// 服务返回本地化业务错误；未知系统错误使用当前操作的可读摘要。
    private func serviceError(_ error: Error, fallback: ActionError) -> ActionError {
        guard let message = (error as? SkillEvaluationFailure)?.localizedDescription else { return fallback }
        return .service(message)
    }
}
