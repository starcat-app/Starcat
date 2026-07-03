//
//  CompanionActionHandler.swift
//  Starcat
//
//  Browser Plugin 打开动作处理。
//
//  本机 HTTP 服务不能直接持有 SwiftUI sheet 状态, 否则会把网络层和页面生命周期绑死。
//  这里拆成两层: Handler 做请求校验与 repo 查找, Dispatcher 只在 MainActor 上发布
//  "需要打开某个 UI"的瞬时事件, 由稳定页面根视图负责呈现。
//

import Foundation

enum CompanionOpenAction: String, Codable, Equatable {
    case openRepo = "open-repo"
    case generateSummary = "generate-summary"
    case codeflow
    case codebase
}

enum CompanionActionError: Error, Equatable {
    case invalidAction
    case repoNotFound
    case repoNotStarred
    case requiresPro(ProFeature)
}

@MainActor
@Observable
final class CompanionActionDispatcher {
    struct Request: Identifiable, Equatable {
        enum Kind: Equatable {
            case openRepo
            case generateSummary
            case codeflow
            case codebase
        }

        let id = UUID()
        let kind: Kind
        let repo: Repo
    }

    var pendingRequest: Request?

    func requestOpenRepo(_ repo: Repo) {
        publish(Request(kind: .openRepo, repo: repo))
    }

    func requestGenerateSummary(_ repo: Repo) {
        publish(Request(kind: .generateSummary, repo: repo))
    }

    func requestCodeFlow(for repo: Repo) {
        publish(Request(kind: .codeflow, repo: repo))
    }

    func requestCodebase(for repo: Repo) {
        publish(Request(kind: .codebase, repo: repo))
    }

    private func publish(_ request: Request) {
        pendingRequest = request
        // Browser Plugin 的 action 可能在主窗口关闭时到达。先保存请求，再恢复主窗口；
        // 新窗口挂载后会消费这份 pendingRequest 并定位到目标 repo。
        AppDelegate.activateMainWindowIfPossible()
    }
}

struct CompanionActionHandler {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let lookupLibraryState: @Sendable (Int64) async throws -> LibraryState
    private let requestOpenRepo: @MainActor @Sendable (Repo) -> Void
    private let requestGenerateSummary: @MainActor @Sendable (Repo) -> Void
    private let requestCodeFlow: @MainActor @Sendable (Repo) -> Void
    private let requestCodebase: @MainActor @Sendable (Repo) -> Void
    private let isProUser: @Sendable () async -> Bool

    init(
        repoRepository: any RepoRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        dispatcher: CompanionActionDispatcher,
        entitlementGate: EntitlementGate? = nil
    ) {
        self.init(
            lookupRepo: { owner, name in
                try await repoRepository.findByOwnerName(owner: owner, name: name)
            },
            lookupLibraryState: { repoID in
                try await repoNoteRepository.fetchLibraryState(repoId: repoID)
            },
            requestOpenRepo: { repo in
                dispatcher.requestOpenRepo(repo)
            },
            requestGenerateSummary: { repo in
                dispatcher.requestGenerateSummary(repo)
            },
            requestCodeFlow: { repo in
                dispatcher.requestCodeFlow(for: repo)
            },
            requestCodebase: { repo in
                dispatcher.requestCodebase(for: repo)
            },
            isProUser: {
                await MainActor.run {
                    entitlementGate?.isProUser ?? false
                }
            }
        )
    }

    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        lookupLibraryState: @escaping @Sendable (Int64) async throws -> LibraryState = { _ in .outsideLibrary },
        requestOpenRepo: @escaping @MainActor @Sendable (Repo) -> Void = { _ in },
        requestGenerateSummary: @escaping @MainActor @Sendable (Repo) -> Void = { _ in },
        requestCodeFlow: @escaping @MainActor @Sendable (Repo) -> Void = { _ in },
        requestCodebase: @escaping @MainActor @Sendable (Repo) -> Void = { _ in },
        isProUser: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.lookupRepo = lookupRepo
        self.lookupLibraryState = lookupLibraryState
        self.requestOpenRepo = requestOpenRepo
        self.requestGenerateSummary = requestGenerateSummary
        self.requestCodeFlow = requestCodeFlow
        self.requestCodebase = requestCodebase
        self.isProUser = isProUser
    }

    func open(owner: String, repo name: String, action: CompanionOpenAction) async throws {
        guard let repo = try await lookupRepo(owner, name) else {
            throw CompanionActionError.repoNotFound
        }
        let libraryState = try await lookupLibraryState(repo.id)
        guard repo.isStarred || libraryState == .inLibrary else {
            throw CompanionActionError.repoNotStarred
        }

        switch action {
        case .openRepo:
            await requestOpenRepo(repo)
        case .generateSummary:
            await requestGenerateSummary(repo)
        case .codeflow:
            guard await isProUser() else { throw CompanionActionError.requiresPro(.codeFlow) }
            await requestCodeFlow(repo)
        case .codebase:
            guard await isProUser() else { throw CompanionActionError.requiresPro(.codebaseMemory) }
            await requestCodebase(repo)
        }
    }
}
