//
//  CuratedProjectResolver.swift
//  Starcat
//
//  把任意项目线索收敛为 GitHub 官方 Search 返回的仓库候选。
//
//  关键约束：
//  - Web Search 只提供候选 URL，不能把网页结果伪装成已核验仓库；
//  - 每个 GitHub URL 都要再经 GitHub Search 精确匹配；
//  - Web Search 是增强项，未配置或请求失败时退化到 GitHub Search；
//  - 最终发布前仍应调用 `verify(address:)`，防止用户编辑 URL 后沿用旧候选。
//

import Foundation

struct CuratedProjectResolution: Equatable, Sendable {
    let candidates: [RepositoryCandidate]
    let usedWebSearch: Bool
    let didFallbackFromWebSearch: Bool
}

protocol CuratedProjectResolving: Sendable {
    func resolve(
        clue: String,
        externalSearchProvider: ExternalSearchProviderID
    ) async throws -> CuratedProjectResolution
    func verify(address: GitHubRepositoryAddress) async throws -> RepositoryCandidate
}

enum CuratedProjectResolverError: Error, LocalizedError {
    case emptyClue
    case repositoryNotFound(String)
    case noCandidates

    var errorDescription: String? {
        switch self {
        case .emptyClue:
            return String.l10n("curatedPublisher.error.emptyClue")
        case .repositoryNotFound(let fullName):
            return String(format: String.l10n("curatedPublisher.error.repositoryNotFoundFormat"), fullName)
        case .noCandidates:
            return String.l10n("curatedPublisher.error.noCandidates")
        }
    }
}

struct CuratedProjectResolver: CuratedProjectResolving {
    private let githubProvider: any SearchProvider
    private let webProvider: (any SearchProvider)?

    init(
        githubProvider: any SearchProvider,
        webProvider: (any SearchProvider)? = nil
    ) {
        self.githubProvider = githubProvider
        self.webProvider = webProvider
    }

    func resolve(
        clue: String,
        externalSearchProvider: ExternalSearchProviderID
    ) async throws -> CuratedProjectResolution {
        let trimmed = clue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CuratedProjectResolverError.emptyClue }

        if let directAddress = GitHubRepositoryAddress.parse(trimmed) {
            return CuratedProjectResolution(
                candidates: [try await verify(address: directAddress)],
                usedWebSearch: false,
                didFallbackFromWebSearch: false
            )
        }

        var candidates: [RepositoryCandidate] = []
        var didFallbackFromWebSearch = false
        var usedWebSearch = false

        if let webProvider {
            do {
                usedWebSearch = true
                let webPage = try await webProvider.search(
                    SearchRequest(
                        query: searchQuery(from: trimmed) + " GitHub",
                        scope: .web,
                        externalSearchFilters: ExternalSearchFilters(
                            maxResults: 8,
                            freshness: .any,
                            includeDomains: ["github.com"],
                            excludeDomains: []
                        ),
                        externalSearchProvider: externalSearchProvider,
                        perPage: 8
                    )
                )
                candidates.append(contentsOf: await verifiedWebCandidates(from: webPage.references))
            } catch {
                // 外部搜索凭据可能未配置；GitHub Search 仍能完成核心识别，不能让增强项阻断。
                didFallbackFromWebSearch = true
            }
        }

        do {
            let githubPage = try await githubProvider.search(
                SearchRequest(
                    query: searchQuery(from: trimmed),
                    scope: .github,
                    page: 1,
                    perPage: 8
                )
            )
            candidates.append(contentsOf: githubPage.repositories)
        } catch where !candidates.isEmpty {
            // Web 候选已经逐一通过 GitHub 精确核验时，通用 GitHub 搜索失败不应丢掉真结果。
        }

        let deduplicated = deduplicate(candidates)
        guard !deduplicated.isEmpty else { throw CuratedProjectResolverError.noCandidates }
        return CuratedProjectResolution(
            candidates: deduplicated,
            usedWebSearch: usedWebSearch,
            didFallbackFromWebSearch: didFallbackFromWebSearch
        )
    }

    func verify(address: GitHubRepositoryAddress) async throws -> RepositoryCandidate {
        let page = try await githubProvider.search(
            SearchRequest(
                query: "repo:\(address.owner)/\(address.repo)",
                scope: .github,
                page: 1,
                perPage: 5
            )
        )
        guard let exact = page.repositories.first(where: {
            $0.identity.normalizedFullName == address.normalizedFullName
        }) else {
            throw CuratedProjectResolverError.repositoryNotFound("\(address.owner)/\(address.repo)")
        }
        return exact
    }

    /// Web Search 结果最多核验前三个 GitHub repo URL，避免一个噪声页面放大为大量 API 请求。
    private func verifiedWebCandidates(from references: [ReferenceCandidate]) async -> [RepositoryCandidate] {
        var addresses: [GitHubRepositoryAddress] = []
        var seen: Set<String> = []
        for reference in references {
            guard let address = GitHubRepositoryAddress.parse(reference.normalizedURL.absoluteString),
                  seen.insert(address.normalizedFullName).inserted
            else { continue }
            addresses.append(address)
            if addresses.count == 3 { break }
        }

        var candidates: [RepositoryCandidate] = []
        for address in addresses {
            if let candidate = try? await verify(address: address) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func searchQuery(from clue: String) -> String {
        guard let url = URL(string: clue), let host = url.host else { return clue }
        let pathWords = url.pathComponents
            .filter { $0 != "/" }
            .suffix(3)
            .joined(separator: " ")
        let query = [host, pathWords].filter { !$0.isEmpty }.joined(separator: " ")
        return query.isEmpty ? clue : query
    }

    private func deduplicate(_ candidates: [RepositoryCandidate]) -> [RepositoryCandidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.identity.normalizedFullName).inserted }
    }
}
