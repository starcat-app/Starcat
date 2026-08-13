//
//  CuratedPublisherSession.swift
//  Starcat
//
//  精选发布台的 App 级状态机：连接、识别、确认、提交、恢复与轮询。
//
//  为什么由 AppDependencies 持有而不是放在 View：独立窗口关闭后，已经持久化的
//  weekly-api 批次仍应继续轮询；View 生命周期不能决定服务端任务是否被追踪。
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

    func loadLastBatchID() -> String? {
        defaults.string(forKey: Self.key)
    }

    func storeLastBatchID(_ batchID: String) {
        defaults.set(batchID, forKey: Self.key)
    }
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
    case resolving
    case verifying
    case publishing
    case polling
}

enum CuratedPublisherSessionError: Error, LocalizedError {
    case accessDenied
    case missingAdminKey
    case noManualSources
    case invalidFinalURL
    case invalidSourceURL
    case unverifiedRepository
    case confirmationRequired

    var errorDescription: String? {
        switch self {
        case .accessDenied: String.l10n("curatedPublisher.error.accessDenied")
        case .missingAdminKey: String.l10n("curatedPublisher.error.missingAdminKey")
        case .noManualSources: String.l10n("curatedPublisher.error.noManualSources")
        case .invalidFinalURL: String.l10n("curatedPublisher.error.invalidFinalURL")
        case .invalidSourceURL: String.l10n("curatedPublisher.error.invalidSourceURL")
        case .unverifiedRepository: String.l10n("curatedPublisher.error.unverifiedRepository")
        case .confirmationRequired: String.l10n("curatedPublisher.error.confirmationRequired")
        }
    }
}

@MainActor
@Observable
final class CuratedPublisherSession {
    /// 连续失败达到上限后暂停后台请求，避免服务长期不可用时每两秒持续打点。
    /// 批次 ID 会保留，维护者可从状态卡片手动恢复查询。
    private static let maximumConsecutivePollFailures = 3

    var clue: String = "" {
        didSet {
            guard clue != oldValue else { return }
            clearResolution()
        }
    }
    var candidates: [RepositoryCandidate] = []
    private(set) var verifiedCandidate: RepositoryCandidate?
    var finalGitHubURL: String = "" {
        didSet {
            guard finalGitHubURL != oldValue,
                  finalGitHubURL != verifiedCandidate?.canonicalGitHubURL.absoluteString
            else { return }
            verifiedCandidate = nil
            hasConfirmedOfficialRepository = false
        }
    }
    var displayTitle: String = ""
    var sourceURL: String = ""
    var hasConfirmedOfficialRepository = false
    var sources: [CuratedPublisherSource] = []
    var selectedSourceCode: String?
    private(set) var operation: CuratedPublisherOperation = .idle
    private(set) var isAdminConnected = false
    private(set) var didFallbackFromWebSearch = false
    private(set) var batch: CuratedPublisherBatch?
    private(set) var errorMessage: String?

    @ObservationIgnored private let resolver: any CuratedProjectResolving
    @ObservationIgnored private let api: any CuratedPublisherAPIProtocol
    @ObservationIgnored private let credentialStore: any CuratedPublisherCredentialStoring
    @ObservationIgnored private let batchTracker: any CuratedPublisherBatchTracking
    @ObservationIgnored private let sleeper: any CuratedPublisherSleeping
    @ObservationIgnored private var adminKey: String?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(
        resolver: any CuratedProjectResolving,
        api: any CuratedPublisherAPIProtocol,
        credentialStore: any CuratedPublisherCredentialStoring = CuratedPublisherCredentialStore(),
        batchTracker: any CuratedPublisherBatchTracking = UserDefaultsCuratedPublisherBatchTracker(),
        sleeper: any CuratedPublisherSleeping = CuratedPublisherPollSleeper()
    ) {
        self.resolver = resolver
        self.api = api
        self.credentialStore = credentialStore
        self.batchTracker = batchTracker
        self.sleeper = sleeper
    }

    deinit {
        pollingTask?.cancel()
    }

    var selectedSource: CuratedPublisherSource? {
        guard let selectedSourceCode else { return nil }
        return sources.first { $0.code == selectedSourceCode }
    }

    var canPublish: Bool {
        guard operation == .idle,
              isAdminConnected,
              selectedSource != nil,
              hasConfirmedOfficialRepository,
              let candidate = verifiedCandidate,
              GitHubRepositoryAddress.parse(finalGitHubURL)?.normalizedFullName
                == candidate.identity.normalizedFullName
        else { return false }
        return validatedSourceURL != nil || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 窗口首次显示时加载本机 admin key、动态分类和最近批次。
    func bootstrap(currentUserID: Int64?) async {
        guard CuratedPublisherAccessPolicy.canAccess(userID: currentUserID) else {
            resetForDeniedAccess()
            return
        }
        do {
            guard let storedKey = try credentialStore.loadAdminKey(), !storedKey.isEmpty else { return }
            adminKey = storedKey
            try await loadSources(using: storedKey)
            if let batchID = batchTracker.loadLastBatchID(), !batchID.isEmpty {
                try await refreshBatch(id: batchID, adminKey: storedKey)
                if batch?.status.isTerminal == false { startPolling(batchID: batchID) }
            }
        } catch {
            isAdminConnected = false
            errorMessage = error.localizedDescription
        }
    }

    /// 只有服务端接受 admin key 并返回至少一个人工来源后才持久化密钥。
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
            isAdminConnected = false
            sources = []
            selectedSourceCode = nil
        } catch {
            present(error: error)
        }
    }

    func resolveClue(externalSearchProvider: ExternalSearchProviderID) async {
        operation = .resolving
        errorMessage = nil
        do {
            let resolution = try await resolver.resolve(
                clue: clue,
                externalSearchProvider: externalSearchProvider
            )
            candidates = resolution.candidates
            didFallbackFromWebSearch = resolution.didFallbackFromWebSearch
            if candidates.count == 1, let onlyCandidate = candidates.first {
                applyVerifiedCandidate(onlyCandidate)
            } else {
                // 多候选不能替维护者猜答案：保持未核验，必须由用户显式点击候选。
                verifiedCandidate = nil
                finalGitHubURL = ""
                hasConfirmedOfficialRepository = false
            }
            operation = .idle
        } catch {
            operation = .idle
            present(error: error)
        }
    }

    func selectCandidate(_ candidate: RepositoryCandidate) {
        applyVerifiedCandidate(candidate)
    }

    func verifyFinalURL() async {
        guard let address = GitHubRepositoryAddress.parse(finalGitHubURL) else {
            present(error: CuratedPublisherSessionError.invalidFinalURL)
            return
        }
        operation = .verifying
        errorMessage = nil
        do {
            let candidate = try await resolver.verify(address: address)
            applyVerifiedCandidate(candidate)
            operation = .idle
        } catch {
            operation = .idle
            present(error: error)
        }
    }

    /// 提交前再次检查访问者与完整状态，禁止通过绕过 UI disabled 直接调用发布。
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
        guard let address = GitHubRepositoryAddress.parse(finalGitHubURL),
              let candidate = verifiedCandidate,
              address.normalizedFullName == candidate.identity.normalizedFullName
        else {
            present(error: CuratedPublisherSessionError.unverifiedRepository)
            return
        }
        guard hasConfirmedOfficialRepository else {
            present(error: CuratedPublisherSessionError.confirmationRequired)
            return
        }
        guard validatedSourceURL != nil || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            present(error: CuratedPublisherSessionError.invalidSourceURL)
            return
        }

        let title = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CuratedPublisherImportRequest(
            sourceCode: source.code,
            idempotencyKey: CuratedPublisherImportRequest.stableIdempotencyKey(
                sourceCode: source.code,
                address: address,
                originalClue: clue
            ),
            repositories: [
                .init(
                    owner: address.owner,
                    repo: address.repo,
                    title: title.isEmpty ? nil : title,
                    sourceURL: validatedSourceURL?.absoluteString
                )
            ]
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
        clue = ""
        displayTitle = ""
        sourceURL = ""
        clearResolution()
        errorMessage = nil
    }

    /// 后台轮询因连续网络错误暂停后，允许维护者从最近批次继续查询。
    ///
    /// 这里重复执行权限校验，避免调用者绕过只对维护者可见的 UI。
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
            if batch?.status.isTerminal == true {
                operation = .idle
            } else {
                startPolling(batchID: batchID)
            }
        } catch {
            operation = .idle
            present(error: error)
        }
    }

    private var validatedSourceURL: URL? {
        let raw = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil
        else { return nil }
        return url
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

    private func applyVerifiedCandidate(_ candidate: RepositoryCandidate) {
        verifiedCandidate = candidate
        finalGitHubURL = candidate.canonicalGitHubURL.absoluteString
        if displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayTitle = candidate.card.fullName
        }
        hasConfirmedOfficialRepository = false
        errorMessage = nil
    }

    private func clearResolution() {
        candidates = []
        verifiedCandidate = nil
        finalGitHubURL = ""
        hasConfirmedOfficialRepository = false
        didFallbackFromWebSearch = false
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
                        // 保留非终态 batch 与恢复 ID；暂停后由状态卡片显式恢复查询。
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
        isAdminConnected = false
        sources = []
        selectedSourceCode = nil
        present(error: CuratedPublisherSessionError.accessDenied)
    }

    private func present(error: Error) {
        errorMessage = error.localizedDescription
    }
}

private extension RepositoryCandidate {
    var canonicalGitHubURL: URL {
        GitHubRepositoryAddress(owner: identity.owner, repo: identity.name).canonicalURL
    }
}
