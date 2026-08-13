//
//  CuratedProjectIdentificationSession.swift
//  Starcat
//
//  精选发布台的独立 AI 甄别会话。它只依赖 AI、外部搜索与 GitHub 事实核验，
//  不持有 weekly-api 客户端或管理员凭据。
//

import Foundation
import Observation

/// 管理输入、AI 进度、人工复核与最终入选集合。
///
/// 识别成功不等于发布：AI 确认项默认入选，但发布仍由右栏的独立 Weekly 会话完成；
/// `needs_review` 必须经过候选点击或手工 URL 核验才可进入发布集合。
@MainActor
@Observable
final class CuratedProjectIdentificationSession {
    var input = "" {
        didSet {
            guard input != oldValue, phase == .idle else { return }
            clearResults()
        }
    }
    var selectedModelID: String?
    var selectedFindingID: Int?
    var manualRepositoryURL = ""
    private(set) var findings: [CuratedProjectFinding] = []
    private(set) var includedFindingIDs: Set<Int> = []
    private(set) var phase: CuratedProjectIdentificationPhase = .idle
    private(set) var modelName: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any CuratedProjectIdentifying

    init(service: any CuratedProjectIdentifying) {
        self.service = service
    }

    var isRunning: Bool { phase != .idle }

    var selectedFinding: CuratedProjectFinding? {
        findings.first { $0.id == selectedFindingID }
    }

    var publishableFindings: [CuratedProjectFinding] {
        findings.filter { includedFindingIDs.contains($0.id) && $0.isPublishable }
    }

    func identify(externalSearchProvider: ExternalSearchProviderID) async {
        errorMessage = nil
        do {
            let result = try await service.identify(
                input: input,
                externalSearchProvider: externalSearchProvider,
                selectedModelID: selectedModelID
            ) { [weak self] phase in
                self?.phase = phase
            }
            findings = result.findings
            includedFindingIDs = Set(result.confirmedFindings.map(\.id))
            selectedFindingID = result.findings.first?.id
            modelName = result.modelName
            phase = .idle
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    func toggleIncluded(_ finding: CuratedProjectFinding) {
        guard finding.isPublishable else { return }
        if includedFindingIDs.contains(finding.id) {
            includedFindingIDs.remove(finding.id)
        } else {
            includedFindingIDs.insert(finding.id)
        }
    }

    /// AI 待确认项的候选已经过 GitHub API 核验，人工点击后可以显式升级为确认项。
    func confirmCandidate(_ candidate: RepositoryCandidate, for findingID: Int) {
        replaceFinding(id: findingID, repository: candidate)
    }

    /// 手工地址仍需走 GitHub canonical 核验；成功后才替换当前待确认项。
    func verifyManualRepository() async {
        guard let findingID = selectedFindingID else { return }
        errorMessage = nil
        do {
            let candidate = try await service.verify(repositoryURL: manualRepositoryURL)
            replaceFinding(id: findingID, repository: candidate)
            manualRepositoryURL = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        input = ""
        clearResults()
    }

    private func replaceFinding(id: Int, repository: RepositoryCandidate) {
        guard let index = findings.firstIndex(where: { $0.id == id }) else { return }
        let old = findings[index]
        findings[index] = CuratedProjectFinding(
            id: old.id,
            originalText: old.originalText,
            title: old.title,
            sourceURL: old.sourceURL,
            status: .confirmed,
            reason: old.reason,
            repository: repository,
            candidates: old.candidates,
            evidence: old.evidence
        )
        includedFindingIDs.insert(id)
    }

    private func clearResults() {
        findings = []
        includedFindingIDs = []
        selectedFindingID = nil
        manualRepositoryURL = ""
        modelName = nil
        errorMessage = nil
    }
}
