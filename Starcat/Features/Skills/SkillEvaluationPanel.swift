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
    let id: String
    let mode: SkillEvaluationMode
    let selection: Set<SkillEvaluationSubject>
}

/// 使用固定的入口选择，避免其他窗口改变选择时扩大已经展示的发送范围。
struct SkillEvaluationPanel: View {
    let items: [SkillEvaluationPanelItem]
    let service: SkillEvaluationService
    let rememberedTask: Binding<SkillEvaluationPanelTaskLink?>
    let close: () -> Void

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
    @State private var observedTask: (id: String, mode: SkillEvaluationMode)?
    @State private var taskID: String?
    @State private var taskStatus: TaskStatus?
    @State private var failures: [String] = []
    @State private var showsCancelConfirmation = false
    @State private var actionError: ActionError?
    @State private var filePanel: NSSavePanel?

    private struct Confirmation {
        let mode: SkillEvaluationMode
        let providerName: String
        let model: SkillEvaluationSelection
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
    }

    private enum ActionError {
        case service(String), tool, cancel, export

        var text: Text {
            switch self {
            case .service(let message): Text(verbatim: message)
            case .tool: Text("skills.evaluation.error.tool")
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
                        .detailContentTransition()
                } else if let report = selectedReport {
                    let sources = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.source.map { (item.id, $0) } })
                    ScrollView { SkillEvaluationReportDetail(cached: report, sources: sources).padding(20) }
                        .id(report.report.id)
                        .detailContentTransition()
                } else {
                    ScrollView { overview.padding(20) }
                        .detailContentTransition()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: confirmation != nil)
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: selectedReportID)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var header: some View {
        HStack(spacing: 12) {
            if confirmation != nil || selectedReport != nil {
                Button("skills.evaluation.back") {
                    confirmation = nil
                    selectedReportID = nil
                }
                .keyboardShortcut(.cancelAction)
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
            .font(interfaceScale.font(.panelTitle))
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            SheetCloseButton(action: close, helpKey: "skills.evaluation.dismiss")
                .accessibilityLabel(Text("skills.evaluation.dismiss"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            taskFeedback
            if mode != .similarity || items.count >= 2 {
                Divider()
                reportResults
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("skills.evaluation.mode.title", selection: $mode) {
                ForEach(SkillEvaluationMode.allCases, id: \.self) { option in
                    Text(option.panelTitle).tag(option)
                }
            }
            .fixedSize()
            .disabled(taskID != nil)

            switch mode {
            case .quick:
                Text("skills.evaluation.mode.quickNote").foregroundStyle(.secondary)
            case .security:
                Text("skills.evaluation.mode.securityNote").foregroundStyle(.secondary)
            case .similarity where items.count < 2:
                Text("skills.evaluation.mode.similarityNote").foregroundStyle(.secondary)
            default:
                modelControls
                    .disabled(taskID != nil)
            }

            if items.count > 1 {
                Picker("skills.evaluation.filter.title", selection: $filter) {
                    ForEach(SkillEvaluationPanelStatus.allCases, id: \.self) { status in
                        Text(status.title).tag(status)
                    }
                }
                .fixedSize()
                .disabled(records[mode] == nil)
            }
        }
        .font(interfaceScale.font(.body))
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if eligibleProfiles.isEmpty {
                Text("skills.evaluation.configuration.empty").foregroundStyle(.secondary)
            } else {
                Picker("skills.evaluation.configuration.title", selection: $providerID) {
                    Text("skills.evaluation.configuration.select").tag(nil as String?)
                    ForEach(eligibleProfiles) { profile in
                        Text(verbatim: profile.displayName).tag(Optional(profile.id))
                    }
                }
                if let profile = selectedProfile {
                    LabeledContent("skills.evaluation.configuration.endpoint") {
                        Text(verbatim: profile.baseURL).lineLimit(1).truncationMode(.middle).help(profile.baseURL)
                    }
                    if mode.needsChat {
                        modelPicker("skills.evaluation.configuration.chat", placeholder: "skills.evaluation.configuration.chooseChat",
                                    models: enabledModels(in: profile, capability: .chat), selection: $chatName)
                    }
                    if mode.needsEmbedding {
                        modelPicker("skills.evaluation.configuration.embedding",
                                    placeholder: "skills.evaluation.configuration.chooseEmbedding",
                                    models: enabledModels(in: profile, capability: .embedding), selection: $embeddingName)
                    }
                }
            }
        }
    }

    private func modelPicker(
        _ title: LocalizedStringKey, placeholder: LocalizedStringKey,
        models: [AIModelDescriptor], selection: Binding<String?>
    ) -> some View {
        Picker(title, selection: selection) {
            Text(placeholder).tag(nil as String?)
            ForEach(models) { model in Text(verbatim: model.name).tag(Optional(model.name)) }
        }
    }

    @ViewBuilder
    private var taskFeedback: some View {
        if let taskStatus {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if taskID != nil {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(taskStatus.title).font(interfaceScale.font(.body))
                }
                if taskID != nil {
                    Text("skills.evaluation.task.background").foregroundStyle(.secondary)
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
        }
    }

    @ViewBuilder
    private var reportResults: some View {
        if loadFailed {
            HStack {
                Text("skills.evaluation.error.load").foregroundStyle(.secondary)
                Button("skills.evaluation.retry") { reloadRevision += 1 }
            }
        }
        if records[mode] == nil && !loadFailed {
            Text("skills.evaluation.loading")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
            ListLoadingSkeleton(rowCount: min(items.count, 4), showsIcon: false)
                .transition(.opacity)
        } else if records[mode] != nil {
            if filteredItems.isEmpty {
                Text("skills.evaluation.filter.empty").foregroundStyle(.secondary)
            } else if mode == .similarity, let comparisonReport {
                resultRow(name: Text("skills.evaluation.report.comparison"), cached: comparisonReport, index: 0)
            } else {
                let reports = reportBySubject
                LazyVStack(spacing: 2) {
                    ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
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
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .listRowSurface(index: index)
        } else {
            resultRowLabel(name: name, status: .notRun, source: source)
                .padding(8)
                .listRowSurface(index: index)
        }
    }

    private func resultRowLabel(name: Text, status: SkillEvaluationPanelStatus, source: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                name.lineLimit(1)
                if let source {
                    Text(verbatim: source)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(source)
                }
            }
            Spacer(minLength: 8)
            Text(status.title)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        }
        .font(interfaceScale.font(.body))
    }

    private func consentContent(_ consent: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("skills.evaluation.consent.scope")
            Text(consent.mode.consentScope)
            Divider()
            LabeledContent("skills.evaluation.mode.title") { Text(consent.mode.panelTitle) }
            LabeledContent("skills.evaluation.configuration.title") { Text(verbatim: consent.providerName) }
            LabeledContent("skills.evaluation.configuration.endpoint") {
                Text(verbatim: consent.model.endpoint).textSelection(.enabled)
            }
            if !consent.model.chat.isEmpty {
                LabeledContent("skills.evaluation.configuration.chat") { Text(verbatim: consent.model.chat) }
            }
            if let embedding = consent.model.embedding {
                LabeledContent("skills.evaluation.configuration.embedding") { Text(verbatim: embedding) }
            }
            Divider()
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(consent.items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: item.name)
                        if let source = item.source {
                            Text(verbatim: source)
                                .font(interfaceScale.font(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(source)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .listRowSurface(index: index)
                }
            }
        }
        .font(interfaceScale.font(.body))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if let confirmation {
                Spacer()
                Button("skills.evaluation.consent.send") {
                    self.confirmation = nil
                    start(items: confirmation.items, mode: confirmation.mode, model: confirmation.model, consent: true)
                }
                .buttonStyle(.borderedProminent)
            } else if let report = selectedReport {
                Spacer()
                Button("skills.evaluation.report.export") { export([report]) }
            } else {
                Button("skills.evaluation.tool.choose", action: chooseTool)
                    .disabled(taskID != nil || filePanel != nil)
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

    private var filteredItems: [SkillEvaluationPanelItem] {
        guard filter != .all else { return items }
        let reports = reportBySubject
        let comparison = comparisonReport
        return items.filter { SkillEvaluationPanelStatus(comparison ?? reports[$0.id]) == filter }
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
        !loadFailed && records[mode] != nil && !filteredItems.isEmpty
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
        observeTask(link.id, mode: link.mode)
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
            confirmation = Confirmation(mode: mode, providerName: profile.displayName, model: selectedModel, items: selected)
        } else {
            start(items: selected, mode: mode, model: nil, consent: false)
        }
    }

    private func start(
        items: [SkillEvaluationPanelItem], mode: SkillEvaluationMode, model: SkillEvaluationSelection?, consent: Bool
    ) {
        guard taskID == nil else { return }
        let targets = items.map(\.target)
        attachIfRunning(targets: targets, mode: mode)
        guard taskID == nil else { return }
        do {
            let id = try service.start(targets: targets, mode: mode, model: model, consent: consent)
            observeTask(id, mode: mode)
        } catch {
            actionError = serviceError(error, fallback: .service(String.l10n("skills.evaluation.task.failed")))
        }
    }

    private func attachIfRunning(targets: [SkillEvaluationTarget], mode: SkillEvaluationMode) {
        guard taskID == nil, let activeID = service.activeTask(targets: targets, mode: mode) else { return }
        observeTask(activeID, mode: mode)
    }

    private func observeTask(_ id: String, mode: SkillEvaluationMode) {
        guard observedTask?.id != id else { return }
        observedTask = (id, mode)
        failures = []
        taskID = id
        updateTaskStatus(id)
        if taskID != nil {
            // 正在运行的任务已有冻结的输入，回接只观察，关闭可能已打开的发送确认。
            confirmation = nil
            rememberedTask.wrappedValue = SkillEvaluationPanelTaskLink(id: id, mode: mode, selection: Set(items.map(\.id)))
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
        guard filePanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        filePanel = panel
        panel.begin { response in
            guard filePanel === panel else { return }
            filePanel = nil
            guard response == .OK, let url = panel.url else { return }
            do { try service.setExecutable(url) } catch { actionError = serviceError(error, fallback: .tool) }
        }
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
