//
//  CuratedPublisherSession.swift
//  Starcat
//
//  精选发布台的 Weekly 发布会话：管理员连接、动态分类、批量提交、恢复与轮询。
//
//  关键边界：本类型不做自然语言解析、AI 推理或 GitHub 搜索。窗口打开时只从
//  Keychain 读取本机凭据；必须等 AI 甄别成功并激活发布阶段后才访问 weekly-api。
//

import Foundation
import Observation

protocol CuratedPublisherBatchTracking: Sendable {
    func loadLastBatchID() -> String?
    func storeLastBatchID(_ batchID: String)
}

struct UserDefaultsCuratedPublisherBatchTracker: CuratedPublisherBatchTracking, @unchecked Sendable {
    private static let key = "curatedPublisher.lastBatchID.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadLastBatchID() -> String? { defaults.string(forKey: Self.key) }

    func storeLastBatchID(_ batchID: String) { defaults.set(batchID, forKey: Self.key) }
}

protocol CuratedPublisherSleeping: Sendable {
    func sleepBeforeNextPoll() async throws
}

struct CuratedPublisherPollSleeper: CuratedPublisherSleeping {
    func sleepBeforeNextPoll() async throws {
        try await Task.sleep(for: .seconds(2))
    }
}

enum CuratedPublisherOperation: Equatable {
    case idle
    case connecting
    case creatingSource
    case publishing
    case polling
}

enum CuratedPublisherSessionError: Error, LocalizedError {
    case accessDenied
    case missingAdminKey
    case noManualSources
    case noSelectedFindings
    case invalidFinalURL

    var errorDescription: String? {
        switch self {
        case .accessDenied: String.l10n("curatedPublisher.error.accessDenied")
        case .missingAdminKey: String.l10n("curatedPublisher.error.missingAdminKey")
        case .noManualSources: String.l10n("curatedPublisher.error.noManualSources")
        case .noSelectedFindings: String.l10n("curatedPublisher.error.noSelectedFindings")
        case .invalidFinalURL: String.l10n("curatedPublisher.error.invalidFinalURL")
        }
    }
}

/// 维护者确认后的 Weekly 发布状态机。
///
/// `preparedFindings` 只接收识别会话中已核验且被勾选的结果。提交前再次检查每条
/// repository，避免绕过 UI 把 `needs_review` 或 `not_found` 项塞进请求。
@MainActor
@Observable
final class CuratedPublisherSession {
    private static let maximumConsecutivePollFailures = 3

    var sources: [CuratedPublisherSource] = []
    var selectedSourceCode: String?
    private(set) var preparedFindings: [CuratedProjectFinding] = []
    private(set) var operation: CuratedPublisherOperation = .idle
    private(set) var hasStoredAdminCredential = false
    private(set) var isAdminConnected = false
    private(set) var batch: CuratedPublisherBatch?
    private(set) var errorMessage: String?

    @ObservationIgnored private let api: any CuratedPublisherAPIProtocol
    @ObservationIgnored private let credentialStore: any CuratedPublisherCredentialStoring
    @ObservationIgnored private let batchTracker: any CuratedPublisherBatchTracking
    @ObservationIgnored private let sleeper: any CuratedPublisherSleeping
    @ObservationIgnored private var adminKey: String?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(
        api: any CuratedPublisherAPIProtocol,
        credentialStore: any CuratedPublisherCredentialStoring = CuratedPublisherCredentialStore(),
        batchTracker: any CuratedPublisherBatchTracking = UserDefaultsCuratedPublisherBatchTracker(),
        sleeper: any CuratedPublisherSleeping = CuratedPublisherPollSleeper()
    ) {
        self.api = api
        self.credentialStore = credentialStore
        self.batchTracker = batchTracker
        self.sleeper = sleeper
    }

    deinit { pollingTask?.cancel() }

    var selectedSource: CuratedPublisherSource? {
        guard let selectedSourceCode else { return nil }
        return sources.first { $0.code == selectedSourceCode }
    }

    var canPublish: Bool {
        operation == .idle
            && isAdminConnected
            && selectedSource != nil
            && !preparedFindings.isEmpty
            && preparedFindings.allSatisfy(\.isPublishable)
    }

    /// 窗口显示时只读本机凭据，不向 weekly-api 发请求。
    func bootstrap(currentUserID: Int64?) async {
        guard CuratedPublisherAccessPolicy.canAccess(userID: currentUserID) else {
            resetForDeniedAccess()
            return
        }
        do {
            let storedKey = try credentialStore.loadAdminKey()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            adminKey = storedKey?.isEmpty == false ? storedKey : nil
            hasStoredAdminCredential = adminKey != nil
        } catch {
            present(error: error)
        }
    }

    /// AI 甄别成功后才激活发布阶段；此时允许使用已存凭据读取分类和最近批次。
    func activatePublishing(
        findings: [CuratedProjectFinding],
        currentUserID: Int64?
    ) async {
        guard CuratedPublisherAccessPolicy.canAccess(userID: currentUserID) else {
            present(error: CuratedPublisherSessionError.accessDenied)
            return
        }
        setPreparedFindings(findings)
        guard let adminKey else { return }
        operation = .connecting
        errorMessage = nil
        do {
            try await loadSources(using: adminKey)
            if let batchID = batchTracker.loadLastBatchID(), !batchID.isEmpty {
                try await refreshBatch(id: batchID, adminKey: adminKey)
                if batch?.status.isTerminal == false { startPolling(batchID: batchID) }
            }
            if operation == .connecting { operation = .idle }
        } catch {
            operation = .idle
            isAdminConnected = false
            present(error: error)
        }
    }

    /// 入选项变化只更新本地发布草稿，不触发任何网络请求。
    func setPreparedFindings(_ findings: [CuratedProjectFinding]) {
        preparedFindings = findings.filter(\.isPublishable)
    }

    /// 只有服务端接受 admin key 并返回人工来源后才持久化密钥。
    func connect(adminKey rawKey: String, currentUserID: Int64?) async {
        guard CuratedPublisherAccessPolicy.canAccess(userID: currentUserID) else {
            present(error: CuratedPublisherSessionError.accessDenied)
            return
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            present(error: CuratedPublisherSessionError.missingAdminKey)
            return
        }
        operation = .connecting
        errorMessage = nil
        do {
            try await loadSources(using: key)
            try credentialStore.storeAdminKey(key)
            adminKey = key
            hasStoredAdminCredential = true
            operation = .idle
        } catch {
            operation = .idle
            isAdminConnected = false
            present(error: error)
        }
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        do {
            try credentialStore.deleteAdminKey()
            adminKey = nil
            hasStoredAdminCredential = false
            isAdminConnected = false
            sources = []
            selectedSourceCode = nil
        } catch {
            present(error: error)
        }
    }

    /// 创建分类成功后直接加入来源列表并选中，避免额外刷新请求。
    func createSource(
        code: String,
        displayNameZH: String,
        displayNameEN: String,
        currentUserID: Int64?
    ) async -> Bool {
        guard CuratedPublisherAccessPolicy.canAccess(userID: currentUserID) else {
            present(error: CuratedPublisherSessionError.accessDenied)
            return false
        }
        guard let adminKey, isAdminConnected else {
            present(error: CuratedPublisherSessionError.missingAdminKey)
            return false
        }
        operation = .creatingSource
        errorMessage = nil
        do {
            let created = try await api.createManualSource(
                CuratedPublisherSourceCreationRequest(
                    code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayNameZH: displayNameZH.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayNameEN: displayNameEN.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                adminKey: adminKey
            )
            sources.append(created)
            sources.sort { $0.sortOrder == $1.sortOrder ? $0.code < $1.code : $0.sortOrder < $1.sortOrder }
            selectedSourceCode = created.code
            operation = .idle
            return true
        } catch {
            operation = .idle
            present(error: error)
            return false
        }
    }

    /// 提交前再次检查访问者与全部 finding，禁止绕过 UI 发布未核验项目。
    func publish(currentUserID: Int64?) async {
        guard CuratedPublisherAccessPolicy.canAccess(userID: currentUserID) else {
            present(error: CuratedPublisherSessionError.accessDenied)
            return
        }
        guard let adminKey, isAdminConnected else {
            present(error: CuratedPublisherSessionError.missingAdminKey)
            return
        }
        guard let source = selectedSource else {
            present(error: CuratedPublisherSessionError.noManualSources)
            return
        }
        guard !preparedFindings.isEmpty, preparedFindings.allSatisfy(\.isPublishable) else {
            present(error: CuratedPublisherSessionError.noSelectedFindings)
            return
        }

        let repositories = preparedFindings.compactMap { finding -> CuratedPublisherImportRequest.Repository? in
            guard let repository = finding.repository else { return nil }
            return .init(
                owner: repository.identity.owner,
                repo: repository.identity.name,
                title: finding.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : finding.title,
                sourceURL: finding.sourceURL?.absoluteString
            )
        }
        guard repositories.count == preparedFindings.count else {
            present(error: CuratedPublisherSessionError.noSelectedFindings)
            return
        }
        let request = CuratedPublisherImportRequest(
            sourceCode: source.code,
            idempotencyKey: CuratedPublisherImportRequest.stableIdempotencyKey(
                sourceCode: source.code,
                repositories: repositories
            ),
            repositories: repositories
        )

        operation = .publishing
        errorMessage = nil
        do {
            let acceptance = try await api.submit(request, adminKey: adminKey)
            batchTracker.storeLastBatchID(acceptance.batchID)
            operation = .polling
            try await refreshBatch(id: acceptance.batchID, adminKey: adminKey)
            if batch?.status.isTerminal == false {
                startPolling(batchID: acceptance.batchID)
            } else {
                operation = .idle
            }
        } catch {
            operation = .idle
            present(error: error)
        }
    }

    func clearDraft() {
        preparedFindings = []
        errorMessage = nil
    }

    func retryBatchStatus(currentUserID: Int64?) async {
        guard CuratedPublisherAccessPolicy.canAccess(userID: currentUserID) else {
            present(error: CuratedPublisherSessionError.accessDenied)
            return
        }
        guard let adminKey, isAdminConnected else {
            present(error: CuratedPublisherSessionError.missingAdminKey)
            return
        }
        guard let batchID = batch?.batchID ?? batchTracker.loadLastBatchID(), !batchID.isEmpty else { return }
        operation = .polling
        errorMessage = nil
        do {
            try await refreshBatch(id: batchID, adminKey: adminKey)
            if batch?.status.isTerminal == true { operation = .idle } else { startPolling(batchID: batchID) }
        } catch {
            operation = .idle
            present(error: error)
        }
    }

    private func loadSources(using key: String) async throws {
        let loaded = try await api.fetchManualSources(adminKey: key)
        guard !loaded.isEmpty else { throw CuratedPublisherSessionError.noManualSources }
        sources = loaded
        if !loaded.contains(where: { $0.code == selectedSourceCode }) {
            selectedSourceCode = loaded.first?.code
        }
        isAdminConnected = true
    }

    private func refreshBatch(id: String, adminKey: String) async throws {
        batch = try await api.fetchBatch(id: id, adminKey: adminKey)
    }

    private func startPolling(batchID: String) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await self.sleeper.sleepBeforeNextPoll()
                    guard !Task.isCancelled, let key = self.adminKey else { return }
                    try await self.refreshBatch(id: batchID, adminKey: key)
                    consecutiveFailures = 0
                    self.errorMessage = nil
                    if self.batch?.status.isTerminal == true {
                        self.operation = .idle
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    consecutiveFailures += 1
                    self.present(error: error)
                    if consecutiveFailures >= Self.maximumConsecutivePollFailures {
                        self.operation = .idle
                        return
                    }
                }
            }
        }
    }

    private func resetForDeniedAccess() {
        pollingTask?.cancel()
        pollingTask = nil
        adminKey = nil
        hasStoredAdminCredential = false
        isAdminConnected = false
        sources = []
        selectedSourceCode = nil
        present(error: CuratedPublisherSessionError.accessDenied)
    }

    private func present(error: Error) { errorMessage = error.localizedDescription }
}
