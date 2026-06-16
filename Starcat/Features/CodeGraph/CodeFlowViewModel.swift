//
//  CodeFlowViewModel.swift
//  Starcat
//
//  驱动分支加载、版本检查、固定 commit ZIP、页面生成和浏览器打开流程。
//

import Foundation
import Observation

@MainActor
@Observable
final class CodeFlowViewModel {
    enum State: Equatable {
        case idle
        case ready(pageURL: URL)
        case downloading
        case preparing
        case opening
        case succeeded
        case failed(message: String)
    }

    enum VersionStatus: Equatable {
        case unknown
        case checking
        case current
        case updateAvailable(generated: String, latest: String)
        case branchChanged(generated: String, selected: String)
        case unavailable(String)
    }

    enum RuntimeStepStatus: Equatable {
        case pending
        case running
        case succeeded
        case handedOff
        case failed
    }

    struct RuntimeStep: Identifiable, Equatable {
        let id: String
        let title: String
        var detail: String
        var status: RuntimeStepStatus
        var durationMilliseconds: Int?
    }

    private(set) var state: State = .idle
    private(set) var branches: [CodeFlowBranch] = []
    private(set) var isLoadingBranches = false
    private(set) var versionStatus: VersionStatus = .unknown
    private(set) var storedProject: CodeFlowStoredProject?
    private(set) var steps: [RuntimeStep] = CodeFlowViewModel.emptySteps()
    var selectedBranchName = "" {
        didSet { updateSelectionVersionStatus() }
    }

    private let repo: Repo
    private let runner: CodeFlowRunner
    private var task: Task<Void, Never>?

    var canGenerate: Bool {
        !selectedBranchName.isEmpty
            && branches.contains(where: { $0.name == selectedBranchName })
            && !isLoadingBranches
    }

    init(repo: Repo, runner: CodeFlowRunner = CodeFlowRunner()) {
        self.repo = repo
        self.runner = runner
        restoreCachedState()
    }

    func prepare() async {
        guard branches.isEmpty, !isLoadingBranches else { return }
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        do {
            let loaded = try await runner.branches(repo: repo)
            branches = sortBranches(loaded)
            if selectedBranchName.isEmpty {
                selectedBranchName = storedProject?.metadata.sourceRevision.branch
                    ?? repo.defaultBranch
                    ?? branches.first?.name
                    ?? ""
            }
            await checkSelectedBranchVersion()
        } catch {
            versionStatus = .unavailable(
                String(format: String.l10n("codeFlow.runtime.branchLoadFailedFormat"), error.localizedDescription)
            )
        }
    }

    func selectBranch(_ name: String) {
        selectedBranchName = name
        Task { await checkSelectedBranchVersion() }
    }

    func start() {
        task?.cancel()
        if case .ready(let pageURL) = state {
            openExistingPage(pageURL)
            return
        }
        if case .succeeded = state, let pageURL = storedProject?.pageURL {
            openExistingPage(pageURL)
            return
        }
        generate(removingExisting: false)
    }

    func regenerate() {
        task?.cancel()
        generate(removingExisting: true)
    }

    func cancel() {
        task?.cancel()
        task = nil
        restoreCachedState()
    }

    private func generate(removingExisting: Bool) {
        guard !selectedBranchName.isEmpty else {
            state = .failed(message: CodeFlowError.branchMissing.localizedDescription)
            return
        }

        let previousCount = storedProject?.metadata.generation.generationCount ?? 0
        steps = Self.emptySteps()
        task = Task {
            let startedAt = Date()
            do {
                if removingExisting {
                    try runner.deleteVisualization(owner: repo.owner, name: repo.name)
                    storedProject = nil
                    state = .idle
                }

                let branch = try await runStep(
                    id: "resolveRevision",
                    runningDetail: String(format: String.l10n("codeFlow.runtime.resolveRevisionFormat"), selectedBranchName)
                ) {
                    try await runner.resolveBranch(repo: repo, name: selectedBranchName)
                } successDetail: { "\($0.name) · \($0.shortSHA)" }

                try Task.checkCancellation()
                state = .downloading
                let archive = try await runStep(
                    id: "download",
                    runningDetail: String.l10n("codeFlow.runtime.downloadingZip")
                ) {
                    try await runner.archiveIfNeeded(repo: repo, commitSHA: branch.commitSHA)
                } successDetail: { archive in
                    let bytes = Self.byteText(archive.bytes)
                    if archive.wasDownloaded {
                        return String(format: String.l10n("codeFlow.runtime.downloadedZipFormat"), bytes)
                    }
                    return String(format: String.l10n("codeFlow.runtime.cachedZipFormat"), bytes)
                }

                try Task.checkCancellation()
                state = .preparing
                setStep(id: "generatePage", status: .running, detail: String.l10n("codeFlow.runtime.injectingZip"))
                let generateStartedAt = Date()
                let persistedSteps = successfulMetadataSteps(excluding: ["generatePage", "openBrowser", "browserAnalysis"])
                let project = try runner.makeVisualizationPage(
                    archive: archive,
                    repo: repo,
                    branch: branch,
                    startedAt: startedAt,
                    steps: persistedSteps,
                    previousGenerationCount: previousCount
                )
                setStep(
                    id: "generatePage",
                    status: .succeeded,
                    detail: String.l10n("codeFlow.runtime.pageWritten"),
                    duration: CodeFlowRunner.milliseconds(from: generateStartedAt)
                )

                try Task.checkCancellation()
                state = .opening
                let openStartedAt = Date()
                setStep(id: "openBrowser", status: .running, detail: String.l10n("codeFlow.runtime.handingToBrowser"))
                guard try runner.openVisualization(project.pageURL) else {
                    throw NSError(
                        domain: "Starcat.CodeFlow",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String.l10n("codeFlow.error.browserOpenFailed")]
                    )
                }
                setStep(
                    id: "openBrowser",
                    status: .succeeded,
                    detail: project.pageURL.path,
                    duration: CodeFlowRunner.milliseconds(from: openStartedAt)
                )
                setStep(id: "browserAnalysis", status: .handedOff, detail: String.l10n("codeFlow.runtime.handedToBrowser"))

                let finalProject = try runner.updateExecution(
                    project: project,
                    startedAt: startedAt,
                    steps: successfulMetadataSteps(excluding: [])
                )
                storedProject = finalProject
                versionStatus = .current
                state = .succeeded
            } catch is CancellationError {
                restoreCachedState()
            } catch {
                markRunningStepFailed(error.localizedDescription)
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    /// 已有页面无需重新下载 ZIP 或生成 HTML，直接交给默认浏览器打开。
    private func openExistingPage(_ pageURL: URL) {
        state = .opening
        do {
            guard try runner.openVisualization(pageURL) else {
                state = .failed(message: String.l10n("codeFlow.error.browserOpenFailed"))
                return
            }
            state = .succeeded
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    private func restoreCachedState() {
        do {
            if let project = try runner.existingProject(owner: repo.owner, name: repo.name) {
                storedProject = project
                selectedBranchName = project.metadata.sourceRevision.branch
                steps = Self.runtimeSteps(from: project.metadata.lastExecution.steps)
                state = .ready(pageURL: project.pageURL)
            } else {
                storedProject = nil
                state = .idle
                steps = Self.emptySteps()
            }
        } catch {
            storedProject = nil
            state = .failed(message: error.localizedDescription)
            steps = Self.emptySteps()
        }
    }

    private func checkSelectedBranchVersion() async {
        guard let project = storedProject, !selectedBranchName.isEmpty else {
            versionStatus = .unknown
            return
        }
        let generatedBranch = project.metadata.sourceRevision.branch
        guard selectedBranchName == generatedBranch else {
            versionStatus = .branchChanged(generated: generatedBranch, selected: selectedBranchName)
            return
        }
        versionStatus = .checking
        do {
            let latest = try await runner.resolveBranch(repo: repo, name: selectedBranchName)
            let generatedSHA = project.metadata.sourceRevision.commitSHA
            versionStatus = latest.commitSHA == generatedSHA
                ? .current
                : .updateAvailable(generated: String(generatedSHA.prefix(7)), latest: latest.shortSHA)
        } catch {
            versionStatus = .unavailable(
                String(format: String.l10n("codeFlow.version.checkFailedFormat"), error.localizedDescription)
            )
        }
    }

    private func updateSelectionVersionStatus() {
        guard let project = storedProject else { return }
        let generated = project.metadata.sourceRevision.branch
        if !selectedBranchName.isEmpty, selectedBranchName != generated {
            versionStatus = .branchChanged(generated: generated, selected: selectedBranchName)
        }
    }

    private func sortBranches(_ values: [CodeFlowBranch]) -> [CodeFlowBranch] {
        let generated = storedProject?.metadata.sourceRevision.branch
        let defaultBranch = repo.defaultBranch
        return values.sorted { lhs, rhs in
            func rank(_ name: String) -> Int {
                if name == generated { return 0 }
                if name == defaultBranch { return 1 }
                return 2
            }
            let leftRank = rank(lhs.name)
            let rightRank = rank(rhs.name)
            return leftRank == rightRank
                ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                : leftRank < rightRank
        }
    }

    private func runStep<T>(
        id: String,
        runningDetail: String,
        operation: () async throws -> T,
        successDetail: (T) -> String
    ) async throws -> T {
        let startedAt = Date()
        setStep(id: id, status: .running, detail: runningDetail)
        do {
            let value = try await operation()
            setStep(
                id: id,
                status: .succeeded,
                detail: successDetail(value),
                duration: CodeFlowRunner.milliseconds(from: startedAt)
            )
            return value
        } catch {
            setStep(id: id, status: .failed, detail: error.localizedDescription, duration: CodeFlowRunner.milliseconds(from: startedAt))
            throw error
        }
    }

    private func setStep(id: String, status: RuntimeStepStatus, detail: String, duration: Int? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].status = status
        steps[index].detail = detail
        steps[index].durationMilliseconds = duration
    }

    private func markRunningStepFailed(_ message: String) {
        guard let index = steps.firstIndex(where: { $0.status == .running }) else { return }
        steps[index].status = .failed
        steps[index].detail = message
    }

    private func successfulMetadataSteps(excluding excluded: Set<String>) -> [CodeFlowExecutionStep] {
        steps.compactMap { step in
            guard !excluded.contains(step.id) else { return nil }
            let status: CodeFlowExecutionStep.Status
            switch step.status {
            case .succeeded: status = .succeeded
            case .handedOff: status = .handedOff
            default: return nil
            }
            return CodeFlowExecutionStep(
                id: step.id,
                status: status,
                durationMilliseconds: step.durationMilliseconds,
                summary: step.detail
            )
        }
    }

    private static func emptySteps() -> [RuntimeStep] {
        let pendingDetail = String.l10n("codeFlow.step.detail.pending")
        let handoffDetail = String.l10n("codeFlow.step.detail.awaitingHandoff")
        return [
            RuntimeStep(
                id: "resolveRevision",
                title: String.l10n("codeFlow.step.resolveRevision.title"),
                detail: pendingDetail,
                status: .pending
            ),
            RuntimeStep(
                id: "download",
                title: String.l10n("codeFlow.step.download.title"),
                detail: pendingDetail,
                status: .pending
            ),
            RuntimeStep(
                id: "generatePage",
                title: String.l10n("codeFlow.step.generatePage.title"),
                detail: pendingDetail,
                status: .pending
            ),
            RuntimeStep(
                id: "openBrowser",
                title: String.l10n("codeFlow.step.openBrowser.title"),
                detail: pendingDetail,
                status: .pending
            ),
            RuntimeStep(
                id: "browserAnalysis",
                title: String.l10n("codeFlow.step.browserAnalysis.title"),
                detail: handoffDetail,
                status: .pending
            )
        ]
    }

    private static func runtimeSteps(from values: [CodeFlowExecutionStep]) -> [RuntimeStep] {
        var result = emptySteps()
        for value in values {
            guard let index = result.firstIndex(where: { $0.id == value.id }) else { continue }
            result[index].detail = value.summary
            result[index].durationMilliseconds = value.durationMilliseconds
            result[index].status = value.status == .handedOff ? .handedOff : .succeeded
        }
        return result
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
