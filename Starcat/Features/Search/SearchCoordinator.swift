//
//  SearchCoordinator.swift
//  Starcat
//
//  全局搜索中心的 Provider 编排器。
//
//  关键约束：
//  - provider 独立成功/失败，任何单点故障都不能清空其它来源结果；
//  - 每次提交生成单调递增 generation，旧请求即使不响应 cancellation，返回后也会被丢弃；
//  - Coordinator 只编排与合并，不执行 Star、分享、AI、浏览器等业务动作。
//

import Foundation
import Observation

@MainActor
@Observable
final class SearchCoordinator {
    private(set) var statuses: [SearchSource: SearchProviderStatus] = [:]
    private(set) var repositories: [RepositoryCandidate] = []
    private(set) var references: [ReferenceCandidate] = []

    private let providers: [any SearchProvider]
    private var activeTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(providers: [any SearchProvider]) {
        self.providers = providers
    }

    func reset() {
        activeTask?.cancel()
        generation &+= 1
        statuses = [:]
        repositories = []
        references = []
    }

    /// 提交新搜索并等待当前 generation 的 Provider 全部结束。
    ///
    /// ViewModel 可以选择 await 以驱动测试，也可以包在自己的 Task 中调用。
    func search(_ request: SearchRequest) async {
        activeTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let selectedProviders = providers.filter { Self.shouldRun($0.source, for: request) }

        if request.query.isEmpty {
            reset()
            return
        }

        repositories = []
        references = []
        statuses = Dictionary(uniqueKeysWithValues: selectedProviders.map { ($0.source, .loading) })

        let task = Task { [providers = selectedProviders] in
            await withTaskGroup(of: ProviderOutcome.self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            return ProviderOutcome(
                                source: provider.source,
                                result: .success(try await provider.search(request))
                            )
                        } catch {
                            return ProviderOutcome(source: provider.source, result: .failure(error))
                        }
                    }
                }

                for await outcome in group {
                    guard !Task.isCancelled else { return }
                    self.consume(outcome, generation: requestGeneration)
                }
            }
        }
        activeTask = task
        await task.value
    }

    func status(for source: SearchSource) -> SearchProviderStatus {
        statuses[source] ?? .idle
    }

    /// 只追加单一来源的下一页。分页不能复用 `search`，因为后者会清空已有本地与远端
    /// 结果；这里仍递增 generation，保证快速连续点击时旧页不会迟到写回。
    func loadMore(_ request: SearchRequest, source: SearchSource) async {
        guard let provider = providers.first(where: { $0.source == source }) else { return }
        activeTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        statuses[source] = .loading

        let task = Task {
            do {
                let page = try await provider.search(request)
                guard !Task.isCancelled, requestGeneration == generation else { return }
                statuses[source] = .loaded(page)
                repositories = Self.mergeRepositories(existing: repositories, incoming: page.repositories)
                references = Self.mergeReferences(existing: references, incoming: page.references)
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                statuses[source] = .failed(error.localizedDescription)
            }
        }
        activeTask = task
        await task.value
    }

    private func consume(_ outcome: ProviderOutcome, generation outcomeGeneration: UInt64) {
        guard outcomeGeneration == generation else { return }

        switch outcome.result {
        case .success(let page):
            statuses[outcome.source] = .loaded(page)
            repositories = Self.mergeRepositories(
                existing: repositories,
                incoming: page.repositories
            )
            references = Self.mergeReferences(existing: references, incoming: page.references)
        case .failure(let error):
            statuses[outcome.source] = .failed(error.localizedDescription)
        }
    }

    private static func shouldRun(_ source: SearchSource, for request: SearchRequest) -> Bool {
        switch request.scope {
        case .all:
            if source == .web { return request.includeWebInAll }
            return source != .localSemantic
        case .local:
            return source == .localKeyword || source == .localSemantic
        case .github:
            return source == .github
        case .web:
            return source == .web
        }
    }

    /// 合并同一 repo 的来源和本地状态。
    ///
    /// 同时维护 ID 与 fullName 两个索引，解决“一个来源有 ghRepoId、另一个来源只有
    /// owner/name”的情况；`RepoIdentity.Hashable` 本身保持严格合约，不承担模糊匹配。
    static func mergeRepositories(
        existing: [RepositoryCandidate],
        incoming: [RepositoryCandidate]
    ) -> [RepositoryCandidate] {
        var merged = existing

        for candidate in incoming {
            let matchIndex = merged.firstIndex { current in
                if let lhs = current.identity.ghRepoID, let rhs = candidate.identity.ghRepoID, lhs == rhs {
                    return true
                }
                return current.identity.normalizedFullName == candidate.identity.normalizedFullName
            }

            guard let matchIndex else {
                merged.append(candidate)
                continue
            }

            var current = merged[matchIndex]
            current.sources.formUnion(candidate.sources)
            if current.localRepo == nil, let localRepo = candidate.localRepo {
                current.localRepo = localRepo
                current.card = candidate.card
            }
            if current.remoteRepo == nil {
                current.remoteRepo = candidate.remoteRepo
            }
            if current.semanticScore == nil {
                current.semanticScore = candidate.semanticScore
            }
            merged[matchIndex] = current
        }
        return merged
    }

    static func mergeReferences(
        existing: [ReferenceCandidate],
        incoming: [ReferenceCandidate]
    ) -> [ReferenceCandidate] {
        var seen = Set(existing.map(\.id))
        var merged = existing
        for candidate in incoming where seen.insert(candidate.id).inserted {
            merged.append(candidate)
        }
        return merged
    }
}

private struct ProviderOutcome: Sendable {
    let source: SearchSource
    let result: Result<SearchProviderPage, Error>
}
