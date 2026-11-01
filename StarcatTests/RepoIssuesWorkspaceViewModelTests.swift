//
//  RepoIssuesWorkspaceViewModelTests.swift
//  StarcatTests
//
//  工作台回归：通过受控的数据库挂起点复现切帖竞态，不依赖网络或固定时长 sleep。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("RepoIssuesWorkspaceViewModel")
struct RepoIssuesWorkspaceViewModelTests {
    @Test("旧 Issue 的数据库响应不能覆盖后来选中的详情")
    func lateDetailKeepsCurrentSelection() async {
        let first = makeIssue(id: 1)
        let second = makeIssue(id: 2)
        let repository = SuspendedIssueThreadRepository()
        let vm = makeViewModel(threadRepository: repository)
        vm.seedPreviewState(selected: first)

        let oldReload = Task { await vm.reloadDetailAfterInboxChange() }
        await repository.waitUntilFetchStarts()
        vm.seedPreviewState(selected: second)
        await repository.resumeFetch()
        await oldReload.value

        #expect(vm.selectedIssue?.id == second.id)
        #expect(vm.detailItem?.notification?.subjectNumber == second.number)
    }

    @Test("切帖时立即移除旧详情，加载期间不能向旧 Issue 评论")
    func changingSelectionClearsPreviousDetail() {
        let vm = makeViewModel()
        vm.seedPreviewState(selected: makeIssue(id: 1))
        vm.select(makeIssue(id: 2))
        #expect(vm.detailItem == nil)
        #expect(vm.selectedIssue?.id == 2)
    }

    /// 每个测试独占状态和依赖，不使用应用数据库或进程级共享 store。
    private func makeViewModel(
        threadRepository: (any GitHubNotificationThreadRepositoryProtocol)? = nil
    ) -> RepoIssuesWorkspaceViewModel {
        RepoIssuesWorkspaceViewModel(
            repo: makeRepo(),
            listViewModel: RepoIssuesViewModel(client: MockGitHubAPIClient()),
            threadRepository: threadRepository
        )
    }

    private func makeRepo() -> Repo {
        Repo(
            id: 1, owner: "example", name: "repo", fullName: "example/repo",
            description: nil, language: "Swift", starsCount: 0, forksCount: 0,
            watchersCount: 0, topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/example/repo", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: true,
            pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil
        )
    }

    private func makeIssue(id: Int64) -> GitHubRepoIssue {
        GitHubRepoIssue(
            id: id, number: Int(id), title: "Issue \(id)", state: .open,
            body: "Description", htmlURL: URL(string: "https://github.com/example/repo/issues/\(id)")!,
            authorLogin: "author", labels: [], commentsCount: 0,
            createdAt: nil, updatedAt: nil, closedAt: nil
        )
    }
}

/// 仅支持本场景实际会调用的读取；未配置操作直接失败，避免假成功掩盖测试接线错误。
private actor SuspendedIssueThreadRepository: GitHubNotificationThreadRepositoryProtocol {
    private var fetchStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var fetchWaiter: CheckedContinuation<Void, Never>?

    func waitUntilFetchStarts() async {
        if fetchStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func resumeFetch() {
        fetchWaiter?.resume()
        fetchWaiter = nil
    }

    func fetch(id: String) async throws -> GitHubNotificationThreadRecord? {
        fetchStarted = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { fetchWaiter = $0 }
        return GitHubNotificationThreadRecord(
            id: id, reason: "organization", unread: false, githubUnread: false,
            repositoryId: 1, repositoryFullName: "example/repo", subjectTitle: "Issue 1",
            subjectType: "Issue", subjectApiUrl: "https://api.github.com/repos/example/repo/issues/1",
            subjectNumber: 1, htmlUrl: "https://github.com/example/repo/issues/1",
            actorLogin: "author", subjectCreatedAt: nil, excerpt: "Description",
            commentsJson: nil, hydratedAt: nil, updatedAt: "2026-11-01T00:00:00Z",
            firstSeenAt: "2026-11-01T00:00:00Z", notifiedAt: nil,
            markReadState: "synced", fetchedAt: "2026-11-01T00:00:00Z"
        )
    }

    func fetchAll(limit: Int) async throws -> [GitHubNotificationThreadRecord] { fatalError("Unexpected fetchAll") }
    func unreadCount() async throws -> Int { fatalError("Unexpected unreadCount") }
    func totalCount() async throws -> Int { fatalError("Unexpected totalCount") }
    func upsertMany(_ records: [GitHubNotificationThreadRecord]) async throws { fatalError("Unexpected upsertMany") }
    func upsertOrganizationIssues(_ issues: [GitHubOrganizationIssue], credentialSource: GitHubTimelineCredentialSource, fetchedAt: String) async throws { fatalError("Unexpected upsertOrganizationIssues") }
    func updateLocalUnread(id: String, unread: Bool, markReadState: GitHubNotificationMarkReadState, githubUnread: Bool?) async throws { fatalError("Unexpected updateLocalUnread") }
    func updateHydration(id: String, actorLogin: String?, excerpt: String?, commentsJson: String?, htmlUrl: String?, subjectCreatedAt: String?, hydratedAt: String, labelsJson: String?) async throws { fatalError("Unexpected updateHydration") }
    func updatePersistedIssueState(id: String, state: String) async throws { fatalError("Unexpected updatePersistedIssueState") }
    func fetchIDsMissingIssueState(limit: Int) async throws -> [String] { fatalError("Unexpected fetchIDsMissingIssueState") }
    func markNotified(ids: [String], notifiedAt: String) async throws { fatalError("Unexpected markNotified") }
    func fetchFailedMarkRead() async throws -> [GitHubNotificationThreadRecord] { fatalError("Unexpected fetchFailedMarkRead") }
    func fetchUnnotified() async throws -> [GitHubNotificationThreadRecord] { fatalError("Unexpected fetchUnnotified") }
    func maxUpdatedAt() async throws -> String? { fatalError("Unexpected maxUpdatedAt") }
    func organizationIssueSyncState(organization: String, credentialSource: GitHubTimelineCredentialSource) async throws -> GitHubOrganizationIssueSyncStateRecord? { fatalError("Unexpected organizationIssueSyncState") }
    func updateOrganizationIssueSyncState(organization: String, credentialSource: GitHubTimelineCredentialSource, nextPage: Int?, watermarkUpdatedAt: String?, backfillCompletedAt: String?, lastFetchedAt: String?, lastError: String?) async throws { fatalError("Unexpected updateOrganizationIssueSyncState") }
    func deleteIDs(withPrefix prefix: String) async throws { fatalError("Unexpected deleteIDs") }
    func delete(id: String) async throws { fatalError("Unexpected delete") }
    func removeNotificationThread(id: String) async throws { fatalError("Unexpected removeNotificationThread") }
}
