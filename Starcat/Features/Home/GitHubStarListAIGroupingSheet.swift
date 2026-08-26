//
//  GitHubStarListAIGroupingSheet.swift
//  Starcat
//
//  GitHub Lists AI 手动整理与审核 Sheet。
//
//  模块职责：
//  - 冻结用户已创建 Lists、Starcat 私有规则和当前 membership；
//  - 复用 BatchAIQueueService 展示进度、暂停、取消与 AI 失败重试；
//  - 在用户确认后按仓库聚合建议，并以每仓库至多一次 GitHub mutation 应用。
//
//  关键约束：建议只存在队列会话内；选中项确认前不调用 GitHub。应用失败时保留选择，
//  再次应用依赖 SyncService 的集合并集与 no-op 语义安全重试。
//

import SwiftUI

private struct GitHubStarListAISuggestionSelection: Hashable {
    let repoID: Int64
    let listID: String
}

private struct GitHubStarListAIReviewRow: Identifiable {
    var id: GitHubStarListAISuggestionSelection { selection }

    let selection: GitHubStarListAISuggestionSelection
    let repoFullName: String
    let listName: String
    let suggestion: GitHubStarListAISuggestion
}

struct GitHubStarListAIGroupingSheet: View {
    let repoRepository: any RepoRepositoryProtocol
    let listService: GitHubStarListSyncService
    let queueService: BatchAIQueueService
    let insightService: RepoAIInsightService
    let entitlementGate: EntitlementGate
    let onApplied: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var reposByID: [Int64: Repo] = [:]
    @State private var listNamesByID: [String: String] = [:]
    @State private var selectedSuggestions: Set<GitHubStarListAISuggestionSelection> = []
    @State private var appliedSuggestions: Set<GitHubStarListAISuggestionSelection> = []
    @State private var didSeedSelection = false
    @State private var isPreparing = false
    @State private var isApplying = false
    @State private var appliedCount = 0
    @State private var applicationFailureCount = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 620)
        .task {
            // 全局 Batch 队列也承载普通摘要/标签和自动分组。只有上一轮“手动 Lists
            // 审核”结果可在重新打开时继续查看，其余已结束批次不能占住本 Sheet 的空态。
            if !queueService.isRunning,
               queueService.options?.actions == [.githubLists],
               queueService.options?.githubListGrouping?.autoApply == false {
                seedSuggestionSelectionIfNeeded()
            } else if !queueService.isRunning {
                queueService.reset()
            }
        }
        .onChange(of: queueService.isFinished) { _, finished in
            if finished { seedSuggestionSelectionIfNeeded() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("githubStarLists.aiGrouping.title")
                    .font(.headline)
                Text("githubStarLists.aiGrouping.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SheetCloseButton { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if queueService.jobs.isEmpty {
            introduction
        } else if queueService.isFinished {
            reviewResults
        } else {
            runningProgress
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("githubStarLists.aiGrouping.closedSet", systemImage: "checklist")
                .font(.title3.weight(.semibold))

            Text("githubStarLists.aiGrouping.explanation")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                Label {
                    Text("githubStarLists.aiGrouping.privacy")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(24)
    }

    private var runningProgress: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("githubStarLists.aiGrouping.running")
                .font(.title3.weight(.semibold))
            ProgressView(
                value: Double(queueService.finishedCount),
                total: Double(max(queueService.totalCount, 1))
            )
            Text(
                String(
                    format: String.l10n("githubStarLists.aiGrouping.progressFormat"),
                    queueService.finishedCount,
                    queueService.totalCount
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if let current = queueService.jobs.first(where: { $0.repoId == queueService.currentJobId }) {
                Text(current.repoFullName)
                    .font(.callout.monospaced())
                    .lineLimit(1)
            }

            if !queueService.failedJobs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("githubStarLists.aiGrouping.failed")
                        .font(.subheadline.weight(.semibold))
                    ForEach(queueService.failedJobs.prefix(5)) { job in
                        Text("\(job.repoFullName): \(job.failure?.localizedMessage ?? String.l10n("batchAI.panel.row.failedUnknown"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
    }

    private var reviewResults: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    String(
                        format: String.l10n("githubStarLists.aiGrouping.reviewFormat"),
                        reviewRows.count,
                        Set(selectedSuggestions.map(\.repoID)).count
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                if queueService.failedCount > 0 {
                    Button("githubStarLists.aiGrouping.retryFailed") {
                        // 重试成功后会产生新的建议集合，必须重新生成默认选择。
                        didSeedSelection = false
                        queueService.retryAllFailed()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if reviewRows.isEmpty {
                ContentUnavailableView(
                    "githubStarLists.aiGrouping.noSuggestions",
                    systemImage: "checkmark.circle",
                    description: Text("githubStarLists.aiGrouping.noSuggestions.help")
                )
            } else {
                List {
                    ForEach(groupedReviewRows, id: \.0) { listName, rows in
                        Section(listName) {
                            ForEach(rows) { row in
                                Toggle(isOn: selectionBinding(for: row.selection)) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(row.repoFullName)
                                                .font(.body.monospaced())
                                            Spacer()
                                            Text(row.suggestion.confidence, format: .percent.precision(.fractionLength(0)))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        if !row.suggestion.reason.isEmpty {
                                            Text(row.suggestion.reason)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }

            if appliedCount > 0 || applicationFailureCount > 0 {
                Text(
                    String(
                        format: String.l10n("githubStarLists.aiGrouping.applyResultFormat"),
                        appliedCount,
                        applicationFailureCount
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !queueService.jobs.isEmpty, !queueService.isFinished {
                if queueService.isPaused {
                    Button("batchAI.panel.resume") { queueService.resume() }
                } else {
                    Button("batchAI.panel.pause") { queueService.pause() }
                }
                Button("common.cancel") { queueService.cancel() }
            }

            Spacer()

            Button("action.close") { dismiss() }
                .disabled(isPreparing || isApplying)

            if queueService.jobs.isEmpty {
                Button(isPreparing ? "githubStarLists.aiGrouping.preparing" : "githubStarLists.aiGrouping.start") {
                    Task { await startGrouping() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparing)
            } else if queueService.isFinished, !reviewRows.isEmpty {
                Button(isApplying ? "githubStarLists.aiGrouping.applying" : "githubStarLists.aiGrouping.applySelected") {
                    Task { await applySelectedSuggestions() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying || selectedSuggestions.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var reviewRows: [GitHubStarListAIReviewRow] {
        queueService.jobs.flatMap { job in
            job.suggestedGitHubLists.compactMap { suggestion in
                guard let listName = listNamesByID[suggestion.listId] else { return nil }
                let selection = GitHubStarListAISuggestionSelection(repoID: job.repoId, listID: suggestion.listId)
                guard !appliedSuggestions.contains(selection) else { return nil }
                return GitHubStarListAIReviewRow(
                    selection: selection,
                    repoFullName: job.repoFullName,
                    listName: listName,
                    suggestion: suggestion
                )
            }
        }
    }

    private var groupedReviewRows: [(String, [GitHubStarListAIReviewRow])] {
        Dictionary(grouping: reviewRows, by: \.listName)
            .map { ($0.key, $0.value.sorted { $0.repoFullName < $1.repoFullName }) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private func selectionBinding(for selection: GitHubStarListAISuggestionSelection) -> Binding<Bool> {
        Binding(
            get: { selectedSuggestions.contains(selection) },
            set: { enabled in
                if enabled { selectedSuggestions.insert(selection) }
                else { selectedSuggestions.remove(selection) }
            }
        )
    }

    private func seedSuggestionSelectionIfNeeded() {
        guard !didSeedSelection else { return }
        selectedSuggestions = Set(reviewRows.map(\.selection))
        didSeedSelection = true
    }

    @MainActor
    private func startGrouping() async {
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }

        do {
            try entitlementGate.requirePro(.batchAI)
            // AI 配置在读取仓库和启动批次之前一次性校验。无可用模型时不进入任何
            // repo context 构造或 provider 请求路径，避免无意义的数据读取与失败风暴。
            try insightService.ensureGenerationClientsReady(includeSummary: false, includeTags: true)
            async let listsResult = listService.allLists()
            async let rulesResult = listService.allAIRules()
            async let assignmentsResult = listService.allListAssignments()
            async let reposResult = repoRepository.fetchAllStarred()

            let lists = try await listsResult
            let rules = try await rulesResult
            let assignments = try await assignmentsResult
            let repos = try await reposResult
            let ruleByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
            let candidates = lists.compactMap { list -> GitHubStarListAIContext? in
                guard let rule = ruleByID[list.id],
                      !rule.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return GitHubStarListAIContext(
                    listId: list.id,
                    name: list.name,
                    instruction: rule.instruction,
                    autoApplyEnabled: rule.autoApplyEnabled
                )
            }
            guard !candidates.isEmpty else {
                errorMessage = String.l10n("githubStarLists.aiGrouping.error.noRules")
                return
            }
            guard !repos.isEmpty else {
                errorMessage = String.l10n("githubStarLists.aiGrouping.error.noRepos")
                return
            }

            reposByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
            listNamesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.listId, $0.name) })
            let memberships = assignments.mapValues { Set($0.map(\.id)) }
            await queueService.preemptAutomaticRunForManualStart()
            if !queueService.isRunning { queueService.reset() }
            queueService.start(
                repos: repos,
                options: BatchAIQueueOptions(
                    actions: [.githubLists],
                    autoApplyTags: false,
                    confidenceThreshold: 0.90,
                    maxRetries: 3,
                    githubListGrouping: GitHubStarListAIGroupingConfiguration(
                        candidates: candidates,
                        existingListIDsByRepo: memberships,
                        eligibleRepoIDs: nil,
                        autoApply: false
                    )
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applySelectedSuggestions() async {
        isApplying = true
        applicationFailureCount = 0
        defer { isApplying = false }

        let selectedByRepo = Dictionary(grouping: selectedSuggestions, by: \.repoID)
        var succeededRepos = 0
        var failedRepos = 0
        var successfulSelections: Set<GitHubStarListAISuggestionSelection> = []

        for (repoID, selections) in selectedByRepo {
            guard let repo = reposByID[repoID] else { continue }
            let suggestions = queueService.jobs
                .first(where: { $0.repoId == repoID })?
                .suggestedGitHubLists ?? []
            let approvedListIDs = GitHubStarListAISuggestionPolicy.confirmedListIDs(
                from: suggestions,
                selectedListIDs: Set(selections.map(\.listID)),
                // 本方法只能由“应用所选分组”确认按钮触发；仍把确认建模为显式执行门。
                confirmationGranted: true
            )
            guard !approvedListIDs.isEmpty else { continue }
            do {
                _ = try await listService.addRepo(repo, toLists: approvedListIDs)
                successfulSelections.formUnion(selections)
                succeededRepos += 1
            } catch {
                // 规则、Prompt 和 provider 原文都不进入错误日志；只记录 repo ID 与脱敏错误。
                AppLog.network.error(
                    "GitHub star list AI apply failed for repo=\(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                failedRepos += 1
            }
        }

        selectedSuggestions.subtract(successfulSelections)
        appliedSuggestions.formUnion(successfulSelections)
        appliedCount += succeededRepos
        applicationFailureCount = failedRepos
        if succeededRepos > 0 { await onApplied() }
    }
}
