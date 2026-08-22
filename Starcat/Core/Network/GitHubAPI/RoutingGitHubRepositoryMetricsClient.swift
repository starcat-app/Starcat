//
//  RoutingGitHubRepositoryMetricsClient.swift
//  Starcat
//
//  按仓库身份在 OAuth Metrics 与 GitHub App Metrics 之间路由。
//
//  关键约束：
//  - 路由只发生在「我的项目」私人 / Internal 仓库；公开仓始终走 OAuth，避免 App token
//    与 Stars 登录态混用导致限流桶分裂；
//  - 切库 / 清退避必须同时打到两个底层 client，否则旧账号的 403 冷却会污染新账号；
//  - 本类型不持有 token 本身，只委托 `RepositoryInsightsCredentialResolving`。
//

import Foundation

struct RoutingGitHubRepositoryMetricsClient: GitHubRepositoryMetricsClient {
    private let publicClient: any GitHubRepositoryMetricsClient
    private let projectClient: any GitHubRepositoryMetricsClient
    private let resolver: any RepositoryInsightsCredentialResolving

    init(
        publicClient: any GitHubRepositoryMetricsClient,
        projectClient: any GitHubRepositoryMetricsClient,
        resolver: any RepositoryInsightsCredentialResolving
    ) {
        self.publicClient = publicClient
        self.projectClient = projectClient
        self.resolver = resolver
    }

    func clearTransientState() async {
        await publicClient.clearTransientState()
        await projectClient.clearTransientState()
    }

    func beginDatabaseScopeChange() async {
        await publicClient.beginDatabaseScopeChange()
        await projectClient.beginDatabaseScopeChange()
    }

    func endDatabaseScopeChange() async {
        await publicClient.endDatabaseScopeChange()
        await projectClient.endDatabaseScopeChange()
    }

    func loadActivityBundle(
        repository: RepoIdentity,
        dateRange: String
    ) async throws -> GitHubRepositoryActivityBundleMetric {
        try await client(for: repository).loadActivityBundle(
            repository: repository,
            dateRange: dateRange
        )
    }

    func searchIssues(
        repository: RepoIdentity,
        query: String,
        sort: String,
        order: String,
        perPage: Int,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryIssueSearch> {
        try await client(for: repository).searchIssues(
            repository: repository,
            query: query,
            sort: sort,
            order: order,
            perPage: perPage,
            observer: observer
        )
    }

    func loadCommitActivity(
        repository: RepoIdentity,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubWeeklyCommitActivity]> {
        try await client(for: repository).loadCommitActivity(
            repository: repository,
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    func loadContributors(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryContributorMetric]> {
        try await client(for: repository).loadContributors(
            repository: repository,
            limit: limit,
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    func loadCommunityProfile(
        repository: RepoIdentity,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<GitHubRepositoryCommunityProfile> {
        try await client(for: repository).loadCommunityProfile(
            repository: repository,
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    func loadIssueTemplateAvailability(
        repository: RepoIdentity,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> Bool {
        try await client(for: repository).loadIssueTemplateAvailability(
            repository: repository,
            observer: observer
        )
    }

    func loadReleases(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositoryReleaseMetric]> {
        try await client(for: repository).loadReleases(
            repository: repository,
            limit: limit,
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    func loadSecurityAdvisories(
        repository: RepoIdentity,
        limit: Int,
        ifNoneMatch: String?,
        observer: GitHubMetricsRequestObserver?
    ) async throws -> GitHubMetricsResponse<[GitHubRepositorySecurityAdvisoryMetric]> {
        try await client(for: repository).loadSecurityAdvisories(
            repository: repository,
            limit: limit,
            ifNoneMatch: ifNoneMatch,
            observer: observer
        )
    }

    private func client(for repository: RepoIdentity) async -> any GitHubRepositoryMetricsClient {
        switch await resolver.credential(for: repository) {
        case .oauth:
            return publicClient
        case .githubApp:
            return projectClient
        }
    }
}
