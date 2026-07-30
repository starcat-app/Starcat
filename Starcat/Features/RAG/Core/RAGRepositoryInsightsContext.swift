//
//  RAGRepositoryInsightsContext.swift
//  Starcat
//
//  仓库洞察 XML 在知识库 RAG 中的目标选择、cache-only 加载与合法 XML 投影。
//
//  关键约束：
//  - 目标只来自用户显式仓库或 Retriever 最终保留 bundle，禁止扫描整个知识库。
//  - 加载固定使用 `.cacheOnly`，RAG 问答不能额外扇出 GitHub 请求。
//  - XML 超预算时只能按结构移除明细或整份放弃，禁止字符截断破坏 XML。
//

import Foundation

enum RAGRepositoryInsightsOutcome: String, Codable, Equatable, Sendable {
    case success
    case unavailable
    case degraded
}

/// 持久化审计使用稳定字面量；UI 再把它们翻译成用户可理解的原因。
enum RAGRepositoryInsightsReason {
    static let artifactUnavailable = "artifact_unavailable"
    static let promptPlaceholderMissing = "prompt_placeholder_missing"
    static let totalContextProjectionUnavailable = "total_context_projection_unavailable"
    static let modelContextWindow = "model_context_window"
}

/// 会话历史只保存审计字段，不复制 `insights.xml` 正文。
struct RAGRepositoryInsightsSnapshot: Codable, Equatable, Identifiable, Sendable {
    var repoID: Int64
    var repoFullName: String
    var sourceHash: String?
    var xmlHash: String?
    var generatedAt: Date?
    var configuredTokenBudget: Int
    var originalTokens: Int
    var sentTokens: Int
    var outcome: RAGRepositoryInsightsOutcome
    var wasProjected: Bool
    var projectionReason: String?
    var degradationReason: String?
    var citationMarker: String?
    var preparedAt: Date

    var id: Int64 { repoID }
}

/// XML 正文只在本轮内存中流转；历史回放必须重新核验 repo/source/xml hash。
struct RAGRepositoryInsightsDocument: Equatable, Sendable {
    var snapshot: RAGRepositoryInsightsSnapshot
    var xml: String
}

struct RAGRepositoryInsightsLoadResult: Equatable, Sendable {
    var documents: [RAGRepositoryInsightsDocument]
    var snapshots: [RAGRepositoryInsightsSnapshot]
}

/// 历史回答只保留审计快照；回放时必须证明磁盘 Artifact 仍是当轮使用的同一份内容。
/// 任一身份或 hash 不匹配都返回 nil，绝不把后来更新的洞察冒充旧回答证据。
enum RAGRepositoryInsightsHistoryRestorer {
    static func restore(
        snapshot: RAGRepositoryInsightsSnapshot,
        artifact: RepositoryInsightsContextArtifact
    ) -> RAGRepositoryInsightsDocument? {
        guard snapshot.outcome == .success,
              snapshot.sentTokens > 0,
              artifact.metadata.repositoryID == snapshot.repoID,
              artifact.metadata.repositoryFullName == snapshot.repoFullName,
              artifact.metadata.sourceHash == snapshot.sourceHash,
              artifact.metadata.xmlHash == snapshot.xmlHash,
              let projection = try? RAGRepositoryInsightsXMLProjector().project(
                  artifact.document.xml,
                  tokenBudget: snapshot.sentTokens
              )
        else {
            return nil
        }
        var restoredSnapshot = snapshot
        restoredSnapshot.originalTokens = projection.originalTokens
        restoredSnapshot.sentTokens = projection.projectedTokens
        restoredSnapshot.wasProjected = projection.wasProjected
        restoredSnapshot.projectionReason = projection.reason
        return RAGRepositoryInsightsDocument(
            snapshot: restoredSnapshot,
            xml: projection.xml
        )
    }
}

/// 把仓库洞察目标严格收口到本轮真实范围。显式仓库保持用户选择顺序；普通查询保持
/// Retriever bundle 排序，这样加载与 Prompt 中的仓库顺序都可预测。
enum RAGRepositoryInsightsTargetResolver {
    static let maximumRepositoryCount = 8

    static func resolve(
        composerContext: RAGComposerContext,
        candidates: [RAGRepoCandidate],
        retrieval: RAGRetrievalResult,
        limit: Int = maximumRepositoryCount
    ) -> [Repo] {
        let normalizedLimit = max(0, min(limit, maximumRepositoryCount))
        guard normalizedLimit > 0 else { return [] }

        var candidatesByID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.repo.id, $0.repo) }
        )
        for bundle in retrieval.bundles {
            candidatesByID[bundle.candidate.repo.id] = bundle.candidate.repo
        }
        let orderedIDs = composerContext.explicitRepoIDs.isEmpty
            ? retrieval.bundles.map(\.candidate.repo.id)
            : composerContext.explicitRepoIDs
        var seen = Set<Int64>()
        return orderedIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return candidatesByID[id]
        }
        .prefix(normalizedLimit)
        .map { $0 }
    }
}

/// 用小批次 task group 实现有界并发。Provider 自身负责 repo+scope single-flight；这里
/// 只限制一次 RAG 多仓库读取的并发宽度，并保持输入顺序。
struct RAGRepositoryInsightsContextLoader: Sendable {
    private let provider: any RepositoryInsightsRAGContextProviding
    private let configuredTokenBudget: Int
    private let maximumConcurrentLoads: Int
    private let now: @Sendable () -> Date

    init(
        provider: any RepositoryInsightsRAGContextProviding,
        configuredTokenBudget: Int = 8_000,
        maximumConcurrentLoads: Int = 4,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.provider = provider
        self.configuredTokenBudget = min(max(configuredTokenBudget, 512), 32 * 1_024)
        self.maximumConcurrentLoads = min(max(maximumConcurrentLoads, 1), 8)
        self.now = now
    }

    func load(repositories: [Repo]) async -> RAGRepositoryInsightsLoadResult {
        let limitedRepositories = Array(
            repositories.prefix(RAGRepositoryInsightsTargetResolver.maximumRepositoryCount)
        )
        var ordered: [(Int, RAGRepositoryInsightsDocument?, RAGRepositoryInsightsSnapshot)] = []
        for start in stride(from: 0, to: limitedRepositories.count, by: maximumConcurrentLoads) {
            let end = min(start + maximumConcurrentLoads, limitedRepositories.count)
            let batch = Array(limitedRepositories[start..<end].enumerated()).map {
                (index: start + $0.offset, repo: $0.element)
            }
            let provider = self.provider
            let configuredTokenBudget = self.configuredTokenBudget
            let preparedAt = now()
            let batchResults = await withTaskGroup(
                of: (Int, RAGRepositoryInsightsDocument?, RAGRepositoryInsightsSnapshot).self
            ) { group in
                for item in batch {
                    group.addTask {
                        let artifact = await provider.prepareArtifact(
                            for: item.repo,
                            mode: .cacheOnly
                        )
                        guard let artifact else {
                            return (
                                item.index,
                                nil,
                                RAGRepositoryInsightsSnapshot(
                                    repoID: item.repo.id,
                                    repoFullName: item.repo.fullName,
                                    sourceHash: nil,
                                    xmlHash: nil,
                                    generatedAt: nil,
                                    configuredTokenBudget: configuredTokenBudget,
                                    originalTokens: 0,
                                    sentTokens: 0,
                                    outcome: .unavailable,
                                    wasProjected: false,
                                    projectionReason: nil,
                                    degradationReason: RAGRepositoryInsightsReason.artifactUnavailable,
                                    citationMarker: nil,
                                    preparedAt: preparedAt
                                )
                            )
                        }
                        let tokens = TokenEstimator.estimate(text: artifact.document.xml)
                        let snapshot = RAGRepositoryInsightsSnapshot(
                            repoID: item.repo.id,
                            repoFullName: item.repo.fullName,
                            sourceHash: artifact.metadata.sourceHash,
                            xmlHash: artifact.metadata.xmlHash,
                            generatedAt: artifact.document.generatedAt,
                            configuredTokenBudget: configuredTokenBudget,
                            originalTokens: tokens,
                            sentTokens: 0,
                            outcome: .success,
                            wasProjected: false,
                            projectionReason: nil,
                            degradationReason: nil,
                            citationMarker: nil,
                            preparedAt: preparedAt
                        )
                        return (
                            item.index,
                            RAGRepositoryInsightsDocument(
                                snapshot: snapshot,
                                xml: artifact.document.xml
                            ),
                            snapshot
                        )
                    }
                }
                var values: [(Int, RAGRepositoryInsightsDocument?, RAGRepositoryInsightsSnapshot)] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            ordered.append(contentsOf: batchResults)
        }
        ordered.sort { $0.0 < $1.0 }
        return RAGRepositoryInsightsLoadResult(
            documents: ordered.compactMap(\.1),
            snapshots: ordered.map(\.2)
        )
    }
}

struct RAGRepositoryInsightsProjection: Equatable, Sendable {
    var xml: String
    var originalTokens: Int
    var projectedTokens: Int
    var wasProjected: Bool
    var removedDetailCount: Int
    var removedSectionCount: Int
    var reason: String?
}

enum RAGRepositoryInsightsXMLProjectorError: Error, Equatable {
    case invalidXML
    case budgetTooSmall
}

/// 洞察 XML 的摘要字段都在容器属性上；投影时先移除 week/contributor/point 明细，
/// 再按价值从低到高移除整个可选 section，尽量保留 metadata 与聚合事实。
struct RAGRepositoryInsightsXMLProjector {
    func project(
        _ xml: String,
        tokenBudget: Int
    ) throws -> RAGRepositoryInsightsProjection {
        let originalTokens = TokenEstimator.estimate(text: xml)
        guard tokenBudget > 0 else {
            throw RAGRepositoryInsightsXMLProjectorError.budgetTooSmall
        }
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        } catch {
            throw RAGRepositoryInsightsXMLProjectorError.invalidXML
        }
        guard let root = document.rootElement(), root.name == "repository_insights" else {
            throw RAGRepositoryInsightsXMLProjectorError.invalidXML
        }
        guard originalTokens > tokenBudget else {
            return RAGRepositoryInsightsProjection(
                xml: xml,
                originalTokens: originalTokens,
                projectedTokens: originalTokens,
                wasProjected: false,
                removedDetailCount: 0,
                removedSectionCount: 0,
                reason: nil
            )
        }

        // 先把投影审计节点计入预算。计数使用十位占位值做保守预留，最终回填只会变短，
        // 避免“正文刚好装下，追加 projection 后又超限”的边界错误。
        let projection = XMLElement(name: "projection")
        projection.addAttribute(
            XMLNode.attribute(
                withName: "reason",
                stringValue: RAGRepositoryInsightsReason.modelContextWindow
            ) as! XMLNode
        )
        projection.addAttribute(
            XMLNode.attribute(
                withName: "original_tokens",
                stringValue: String(originalTokens)
            ) as! XMLNode
        )
        projection.addAttribute(
            XMLNode.attribute(
                withName: "removed_details",
                stringValue: "9999999999"
            ) as! XMLNode
        )
        projection.addAttribute(
            XMLNode.attribute(
                withName: "removed_sections",
                stringValue: "9999999999"
            ) as! XMLNode
        )
        root.addChild(projection)

        var removedDetails = 0
        let detailPaths = [
            (section: "commit_activity", child: "week"),
            (section: "star_history", child: "point"),
            (section: "contributors", child: "contributor"),
        ]
        for path in detailPaths {
            guard let section = root.elements(forName: path.section).first else { continue }
            while estimatedTokens(document) > tokenBudget,
                  let child = section.elements(forName: path.child).last {
                child.detach()
                removedDetails += 1
            }
        }

        var removedSections = 0
        let removableSections = [
            "recent_activity",
            "security_advisories",
            "community",
            "openssf",
            "release_cadence",
            "latest_release",
            "activity",
            "contributors",
            "commit_activity",
            "star_history",
            "health",
        ]
        for name in removableSections where estimatedTokens(document) > tokenBudget {
            guard let section = root.elements(forName: name).first else { continue }
            section.detach()
            removedSections += 1
        }

        projection.attribute(forName: "removed_details")?.stringValue = String(removedDetails)
        projection.attribute(forName: "removed_sections")?.stringValue = String(removedSections)

        let projectedXML = document.xmlString(options: [.nodePrettyPrint])
        let projectedTokens = TokenEstimator.estimate(text: projectedXML)
        guard !projectedXML.isEmpty, projectedTokens <= tokenBudget else {
            throw RAGRepositoryInsightsXMLProjectorError.budgetTooSmall
        }
        guard let validatedDocument = try? XMLDocument(xmlString: projectedXML),
              validatedDocument.rootElement()?.name == "repository_insights" else {
            throw RAGRepositoryInsightsXMLProjectorError.invalidXML
        }
        return RAGRepositoryInsightsProjection(
            xml: projectedXML,
            originalTokens: originalTokens,
            projectedTokens: projectedTokens,
            wasProjected: true,
            removedDetailCount: removedDetails,
            removedSectionCount: removedSections,
            reason: RAGRepositoryInsightsReason.modelContextWindow
        )
    }

    private func estimatedTokens(_ document: XMLDocument) -> Int {
        TokenEstimator.estimate(text: document.xmlString(options: [.nodePrettyPrint]))
    }
}
