//
//  GlobalRepositorySearchService.swift
//  Starcat
//
//  面向 MCP、CLI 与外部启动器的全局仓库搜索用例。
//
//  本服务只编排现有 Local FTS 与 GitHub Search Provider，不复制查询实现。
//  两个 Provider 并发执行且独立记账：单侧失败仍返回另一侧结果，只有全部失败
//  才抛错，保证 Alfred 在 GitHub 限流或断网时仍能检索本地数据。
//

import Foundation

enum GlobalRepositorySearchSource: String, CaseIterable, Codable, Hashable, Sendable {
    case local
    case github
}

enum GlobalRepositorySearchProviderStatus: String, Codable, Sendable {
    case success
    case failed
}

struct GlobalRepositorySearchProviderState: Sendable {
    let status: GlobalRepositorySearchProviderStatus
    let count: Int
    let message: String?
}

struct GlobalRepositorySearchSnapshot: Sendable {
    let query: String
    let repositories: [RepositoryCandidate]
    let providers: [GlobalRepositorySearchSource: GlobalRepositorySearchProviderState]
    let warnings: [String]
}

enum GlobalRepositorySearchError: LocalizedError {
    case noSources
    case allProvidersFailed

    var errorDescription: String? {
        switch self {
        case .noSources:
            return "At least one repository search source is required."
        case .allProvidersFailed:
            return "Local and GitHub repository search are currently unavailable."
        }
    }
}

@MainActor
final class GlobalRepositorySearchService {
    private let providers: [GlobalRepositorySearchSource: any SearchProvider]

    init(
        localProvider: any SearchProvider,
        githubProvider: any SearchProvider
    ) {
        providers = [
            .local: localProvider,
            .github: githubProvider
        ]
    }

    /// 并发执行选中的来源，然后按“本地在前、GitHub 独有项在后”稳定合并。
    func search(
        query: String,
        limit: Int,
        sources: Set<GlobalRepositorySearchSource>
    ) async throws -> GlobalRepositorySearchSnapshot {
        guard !sources.isEmpty else {
            throw GlobalRepositorySearchError.noSources
        }

        let selected = GlobalRepositorySearchSource.allCases.compactMap { source -> ProviderEntry? in
            guard sources.contains(source), let provider = providers[source] else { return nil }
            return ProviderEntry(source: source, provider: provider)
        }
        var outcomes: [GlobalRepositorySearchSource: ProviderResult] = [:]

        await withTaskGroup(of: ProviderOutcome.self) { group in
            for entry in selected {
                group.addTask {
                    let request = SearchRequest(
                        query: query,
                        scope: entry.source == .local ? .local : .github,
                        perPage: limit
                    )
                    do {
                        return ProviderOutcome(
                            source: entry.source,
                            result: .success(try await entry.provider.search(request))
                        )
                    } catch {
                        return ProviderOutcome(source: entry.source, result: .failure(error))
                    }
                }
            }

            for await outcome in group {
                outcomes[outcome.source] = outcome.result
            }
        }

        var providerStates: [GlobalRepositorySearchSource: GlobalRepositorySearchProviderState] = [:]
        var warnings: [String] = []
        var successfulPages: [GlobalRepositorySearchSource: SearchProviderPage] = [:]

        for source in GlobalRepositorySearchSource.allCases where sources.contains(source) {
            switch outcomes[source] {
            case .success(let page):
                successfulPages[source] = page
                providerStates[source] = GlobalRepositorySearchProviderState(
                    status: .success,
                    count: page.repositories.count,
                    message: nil
                )
            case .failure:
                let message = Self.providerFailureMessage(for: source)
                providerStates[source] = GlobalRepositorySearchProviderState(
                    status: .failed,
                    count: 0,
                    message: message
                )
                warnings.append(message)
            case nil:
                let message = Self.providerFailureMessage(for: source)
                providerStates[source] = GlobalRepositorySearchProviderState(
                    status: .failed,
                    count: 0,
                    message: message
                )
                warnings.append(message)
            }
        }

        guard !successfulPages.isEmpty else {
            throw GlobalRepositorySearchError.allProvidersFailed
        }

        let local = successfulPages[.local]?.repositories ?? []
        let github = successfulPages[.github]?.repositories ?? []
        let merged = RepositorySearchMerger.merge(existing: local, incoming: github)

        return GlobalRepositorySearchSnapshot(
            query: query,
            repositories: Array(merged.prefix(limit)),
            providers: providerStates,
            warnings: warnings
        )
    }

    /// 对外只返回稳定、可展示的错误，不透出 URL、Token 或底层网络响应正文。
    private static func providerFailureMessage(for source: GlobalRepositorySearchSource) -> String {
        switch source {
        case .local:
            return "Local repository search is currently unavailable."
        case .github:
            return "GitHub repository search is currently unavailable."
        }
    }
}

private struct ProviderEntry: Sendable {
    let source: GlobalRepositorySearchSource
    let provider: any SearchProvider
}

private typealias ProviderResult = Result<SearchProviderPage, Error>

private struct ProviderOutcome: Sendable {
    let source: GlobalRepositorySearchSource
    let result: ProviderResult
}
