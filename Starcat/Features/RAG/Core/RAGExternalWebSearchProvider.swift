//
//  RAGExternalWebSearchProvider.swift
//  Starcat
//
//  将 Starcat 已有 AnySearch / Tavily / Exa / Brave LLM Context Provider 接入 RAG。
//
//  关键约束：这里只消费不可变 Settings 快照，不在后台任务读取 `@Observable AppSettings`；
//  搜索正文只作为本轮 `RAGRemoteContextBlock` 返回，历史执行轨迹最多保存来源标题与 URL，
//  不把网页正文写入数据库。Provider 的 API Key 仍由既有 Registry/Keychain 边界管理。
//

import Foundation

protocol RAGWebSearchProviding: Sendable {
    func fetch(
        requests: [RAGWebSearchRequest],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock]
}

struct EmptyRAGWebSearchProvider: RAGWebSearchProviding {
    func fetch(
        requests: [RAGWebSearchRequest],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] { [] }
}

/// RAG 专用的普通互联网搜索编排器。
///
/// 没有直接复用 `ExternalSearchContextProvider.collect(for:)`，因为后者会为 AI 摘要生成固定
/// 的“文档 / alternatives”查询，无法表达用户本轮问题。本类型复用更底层的稳定抽象
/// `ExternalSearchRegistry` 与 `ExternalSearchProvider`，并沿用设置页的 Provider 选择和
/// Pro 聚合偏好。
struct RAGExternalWebSearchProvider: RAGWebSearchProviding {
    private let settingsSnapshot: ExternalSearchRegistry.SettingsSnapshot
    private let selection: ExternalContextProviderSelection
    private let aggregateEnabled: Bool

    init(
        settingsSnapshot: ExternalSearchRegistry.SettingsSnapshot,
        selection: ExternalContextProviderSelection,
        aggregateEnabled: Bool
    ) {
        self.settingsSnapshot = settingsSnapshot
        self.selection = selection
        self.aggregateEnabled = aggregateEnabled
    }

    func fetch(
        requests: [RAGWebSearchRequest],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] {
        let registry = ExternalSearchRegistry(settingsSnapshot: settingsSnapshot)
        let providerIDs = selectedProviderIDs(registry: registry)
        guard !providerIDs.isEmpty else {
            return requests.enumerated().map { index, request in
                onProgress(RAGRemoteContextFetchProgress(completed: index + 1, total: requests.count))
                return failedBlock(
                    request: request,
                    message: String.l10n("rag.workspace.network.noProvider")
                )
            }
        }

        var blocks: [RAGRemoteContextBlock] = []
        for (index, request) in requests.enumerated() {
            blocks.append(await fetch(request: request, providerIDs: providerIDs, registry: registry))
            onProgress(RAGRemoteContextFetchProgress(completed: index + 1, total: requests.count))
        }
        return blocks
    }

    /// 单 Provider 保留用户显式选择，即使配置不可用也让它返回准确错误；Automatic 和聚合
    /// 只选择 Registry 已确认可用的 Provider，避免一次请求制造多条可预知失败。
    private func selectedProviderIDs(
        registry: ExternalSearchRegistry
    ) -> [ExternalSearchProviderID] {
        if let explicit = selection.explicitProviderID {
            return [explicit]
        }
        let usable = Set(registry.usableProviderIDs())
        let ordered = ExternalSearchProviderID.automaticContextPriority.filter(usable.contains)
        if aggregateEnabled { return ordered }
        return ordered.first.map { [$0] } ?? []
    }

    private func fetch(
        request: RAGWebSearchRequest,
        providerIDs: [ExternalSearchProviderID],
        registry: ExternalSearchRegistry
    ) async -> RAGRemoteContextBlock {
        let startedAt = Date()
        var providerHits: [(ExternalSearchProviderID, ExternalSearchHit)] = []
        var errors: [String] = []

        // 请求量最多 2 × 4，顺序执行能稳定保留设置页优先级和审计顺序；每个 Provider
        // 内部仍由 URLSession 异步运行，不会阻塞主线程。
        for providerID in providerIDs {
            do {
                let response = try await registry.provider(for: providerID).search(ExternalSearchRequest(
                    query: request.query,
                    purpose: .aiContext,
                    maxResults: request.maxResults
                ))
                providerHits.append(contentsOf: response.hits.map { (providerID, $0) })
            } catch {
                errors.append("\(providerID.displayName): \(error.localizedDescription)")
            }
        }

        let hits = deduplicated(providerHits).prefix(request.maxResults).map { $0 }
        let completedAt = Date()
        let providerNames = orderedProviderNames(in: hits, fallback: providerIDs)
        let providerName = providerNames.joined(separator: " + ")
        let previews = hits.prefix(5).map { providerID, hit in
            RAGRemoteResultPreview(
                title: String(hit.title.prefix(180)),
                url: hit.url,
                providerName: providerID.displayName
            )
        }

        if hits.isEmpty {
            return RAGRemoteContextBlock(
                id: request.id,
                repoId: nil,
                resource: .externalWeb,
                title: "\(providerName.isEmpty ? "External Search" : providerName) · Web Search",
                sourceURL: nil,
                content: "",
                fetchedAt: completedAt,
                errorMessage: errors.isEmpty ? nil : errors.joined(separator: "\n"),
                outcome: errors.count == providerIDs.count ? .failed : .empty,
                transport: .network,
                resultCount: 0,
                startedAt: startedAt,
                completedAt: completedAt,
                providerName: providerName.isEmpty ? nil : providerName,
                querySummary: request.query,
                resultPreviews: []
            )
        }

        // GRDB 同时提供 SQL string interpolation；显式标注 String，避免编译器把包含
        // `\(hit.url...)` 的多行文本推断为 SQL。
        let content: String = hits.map { providerID, hit -> String in
            let publishedAt = hit.publishedAt.map { ISO8601DateFormatter.shared.string(from: $0) } ?? "unknown"
            let body = String((hit.extractedText ?? hit.snippet ?? "").prefix(900))
            return """
                [provider=\(providerID.displayName)] \(hit.title)
                url=\(hit.url.absoluteString); published=\(publishedAt)
                \(body)
                """
        }.joined(separator: "\n\n")
        return RAGRemoteContextBlock(
            id: request.id,
            repoId: nil,
            resource: .externalWeb,
            title: "\(providerName) · Web Search",
            sourceURL: hits.first?.1.url,
            content: content,
            fetchedAt: completedAt,
            errorMessage: errors.isEmpty ? nil : errors.joined(separator: "\n"),
            outcome: .success,
            transport: .network,
            resultCount: hits.count,
            startedAt: startedAt,
            completedAt: completedAt,
            providerName: providerName,
            querySummary: request.query,
            resultPreviews: previews
        )
    }

    private func failedBlock(request: RAGWebSearchRequest, message: String) -> RAGRemoteContextBlock {
        let now = Date()
        return RAGRemoteContextBlock(
            id: request.id,
            repoId: nil,
            resource: .externalWeb,
            title: "External Search · Web Search",
            sourceURL: nil,
            content: "",
            fetchedAt: now,
            errorMessage: message,
            outcome: .failed,
            transport: .network,
            resultCount: 0,
            startedAt: now,
            completedAt: now,
            providerName: "External Search",
            querySummary: request.query,
            resultPreviews: []
        )
    }

    private func deduplicated(
        _ values: [(ExternalSearchProviderID, ExternalSearchHit)]
    ) -> [(ExternalSearchProviderID, ExternalSearchHit)] {
        var seen = Set<String>()
        return values.filter { _, hit in
            var components = URLComponents(url: hit.url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            let normalizedHost = components?.host?.lowercased()
            components?.host = normalizedHost
            let key = components?.url?.absoluteString ?? hit.url.absoluteString
            return seen.insert(key).inserted
        }
    }

    private func orderedProviderNames(
        in hits: [(ExternalSearchProviderID, ExternalSearchHit)],
        fallback: [ExternalSearchProviderID]
    ) -> [String] {
        var seen = Set<ExternalSearchProviderID>()
        let ids = hits.map(\.0).filter { seen.insert($0).inserted }
        return (ids.isEmpty ? fallback : ids).map(\.displayName)
    }
}
