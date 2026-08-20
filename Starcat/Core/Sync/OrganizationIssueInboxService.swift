//
//  OrganizationIssueInboxService.swift
//  Starcat
//
//  Activity「组织 Issues」的会话级聚合服务。
//
//  该服务故意不接数据库：公开 OAuth 与 GitHub App 两份凭据的可见范围不同，
//  合并结果可能含私有仓库 Issue。只在内存里保存当前列表，避免数据进入 CloudKit、
//  JSON 导出或 Discovery 等原本只处理 Starcat 本地资料的链路。
//

import Foundation
import Observation

@MainActor
@Observable
final class OrganizationIssueInboxService {

    private enum CredentialSource: String, Hashable {
        case primaryOAuth
        case projectAccess
    }

    private struct Cursor: Hashable {
        let organization: String
        let source: CredentialSource
    }

    private let primaryClient: any GitHubAPIClientProtocol
    private let projectClient: (any GitHubAPIClientProtocol)?
    private let repository: any RepoRepositoryProtocol
    private let isProjectAccessAvailable: () -> Bool
    private let perPage: Int

    private(set) var organizations: [String] = []
    private(set) var issues: [GitHubOrganizationIssue] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    private var nextPages: [Cursor: Int] = [:]

    init(
        primaryClient: any GitHubAPIClientProtocol,
        projectClient: (any GitHubAPIClientProtocol)? = nil,
        repository: any RepoRepositoryProtocol,
        isProjectAccessAvailable: @escaping () -> Bool = { false },
        perPage: Int = 100
    ) {
        self.primaryClient = primaryClient
        self.projectClient = projectClient
        self.repository = repository
        self.isProjectAccessAvailable = isProjectAccessAvailable
        self.perPage = perPage
    }

    var canLoadMore: Bool {
        !nextPages.isEmpty
    }

    /// 首次加载或筛选变化时，从每个目标组织的第一页重新合并。
    /// 单份凭据失败不清空另一份成功结果；只有所有请求都失败时才展示错误。
    func refresh(
        userID: Int64,
        selectedOrganization: String?,
        state: GitHubOrganizationIssueState
    ) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            organizations = try await repository
                .fetchProjectFilterOptions(userID: userID)
                .organizationLogins
        } catch {
            organizations = []
            issues = []
            nextPages = [:]
            errorMessage = error.localizedDescription
            return
        }

        let targets: [String]
        if let selectedOrganization, organizations.contains(selectedOrganization) {
            targets = [selectedOrganization]
        } else {
            targets = organizations
        }

        guard !targets.isEmpty else {
            issues = []
            nextPages = [:]
            return
        }

        var collected: [GitHubOrganizationIssue] = []
        var cursors: [Cursor: Int] = [:]
        var failures: [Error] = []
        var successCount = 0

        for organization in targets {
            for (source, client) in activeClients() {
                do {
                    let response = try await client.organizationIssues(
                        organization: organization,
                        state: state,
                        page: 1,
                        perPage: perPage
                    )
                    successCount += 1
                    collected.append(contentsOf: response.value)
                    if let nextPage = response.linkHeader.nextPage {
                        cursors[Cursor(organization: organization, source: source)] = nextPage
                    }
                } catch is CancellationError {
                    return
                } catch {
                    failures.append(error)
                }
            }
        }

        issues = Self.mergedAndSorted(collected)
        nextPages = cursors
        if successCount == 0 {
            errorMessage = failures.first?.localizedDescription
                ?? String.l10n("activity.organizationIssues.error.generic")
        }
    }

    /// 每个组织 / 凭据 cursor 各前进一页，保持跨组织 updated desc 全局排序。
    func loadMore(state: GitHubOrganizationIssueState) async {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let pending = nextPages
        var updatedCursors = nextPages
        var appended: [GitHubOrganizationIssue] = []

        for (cursor, page) in pending {
            guard let client = client(for: cursor.source) else {
                updatedCursors[cursor] = nil
                continue
            }
            do {
                let response = try await client.organizationIssues(
                    organization: cursor.organization,
                    state: state,
                    page: page,
                    perPage: perPage
                )
                appended.append(contentsOf: response.value)
                updatedCursors[cursor] = response.linkHeader.nextPage
            } catch is CancellationError {
                return
            } catch {
                // 一路分页失败不阻塞其它组织；保留 cursor，用户下次仍可重试。
                AppLog.network.warning(
                    "Organization Issues page failed: org=\(cursor.organization, privacy: .public) source=\(cursor.source.rawValue, privacy: .public) page=\(page, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        nextPages = updatedCursors
        issues = Self.mergedAndSorted(issues + appended)
    }

    private func activeClients() -> [(CredentialSource, any GitHubAPIClientProtocol)] {
        var result: [(CredentialSource, any GitHubAPIClientProtocol)] = [(.primaryOAuth, primaryClient)]
        if isProjectAccessAvailable(), let projectClient {
            result.append((.projectAccess, projectClient))
        }
        return result
    }

    private func client(for source: CredentialSource) -> (any GitHubAPIClientProtocol)? {
        switch source {
        case .primaryOAuth:
            return primaryClient
        case .projectAccess:
            return isProjectAccessAvailable() ? projectClient : nil
        }
    }

    nonisolated static func mergedAndSorted(
        _ values: [GitHubOrganizationIssue]
    ) -> [GitHubOrganizationIssue] {
        var merged: [String: GitHubOrganizationIssue] = [:]
        for issue in values {
            let key = issue.deduplicationKey
            if let current = merged[key] {
                // App token 往往带回更完整的私仓字段；同一条取更新时间较新的版本。
                if (issue.updatedAt ?? .distantPast) >= (current.updatedAt ?? .distantPast) {
                    merged[key] = issue
                }
            } else {
                merged[key] = issue
            }
        }
        return merged.values.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.deduplicationKey < rhs.deduplicationKey
        }
    }
}
