//
//  RepoInsightArtifactBuilder.swift
//  Starcat
//
//  Repo Insight 的结构化 artifact 契约与确定性渲染器。
//
//  模型提交分析判断，宿主校验 repoID 并从本次 run 的冻结快照补齐事实和引用。该实现
//  与 Weekly Report 共用同一 Loop/Tool/Persistence 链路，但不复用周刊专用模板。
//

import Foundation

struct RepoInsightArtifactRequest: Equatable, Sendable {
    var repoID: Int64
    var title: String
    var summary: String
    var positioning: String
    var adoptionFit: String
    var risks: [String]
    var recommendedActions: [String]
    var limitations: [String]
    var includeSources: Bool

    init(arguments: AgentJSONValue) throws {
        guard let object = arguments.objectValue else {
            throw RepoInsightArtifactError.invalidArguments("root must be an object")
        }
        guard let repoID = object["repoID"]?.integerValue else {
            throw RepoInsightArtifactError.invalidArguments("repoID must be an integer")
        }
        self.repoID = Int64(repoID)
        self.title = try Self.requiredString("title", in: object)
        self.summary = try Self.requiredString("summary", in: object)
        self.positioning = try Self.requiredString("positioning", in: object)
        self.adoptionFit = try Self.requiredString("adoptionFit", in: object)
        self.risks = try Self.stringArray("risks", in: object)
        self.recommendedActions = try Self.stringArray("recommendedActions", in: object)
        self.limitations = try Self.stringArray("limitations", in: object)
        self.includeSources = object["includeSources"]?.booleanValue ?? true
    }

    private static func requiredString(
        _ key: String,
        in object: [String: AgentJSONValue]
    ) throws -> String {
        let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw RepoInsightArtifactError.invalidArguments("\(key) must be a non-empty string")
        }
        return value
    }

    private static func stringArray(
        _ key: String,
        in object: [String: AgentJSONValue]
    ) throws -> [String] {
        guard case .array(let values) = object[key] else {
            throw RepoInsightArtifactError.invalidArguments("\(key) must be an array")
        }
        return try values.map { value in
            let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !string.isEmpty else {
                throw RepoInsightArtifactError.invalidArguments("\(key) contains an empty value")
            }
            return string
        }
    }
}

enum RepoInsightArtifactError: LocalizedError, Equatable, Sendable {
    case invalidArguments(String)
    case unknownRepositoryID(Int64)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail):
            return String(format: String.l10n("agent.artifact.repoInsight.error.invalidArgumentsFormat"), detail)
        case .unknownRepositoryID(let id):
            return String(format: String.l10n("agent.artifact.repoInsight.error.unknownRepositoryFormat"), id)
        }
    }
}

enum RepoInsightArtifactBuilder {
    static func build(
        request: RepoInsightArtifactRequest,
        prompt: String,
        context: AgentRunContext,
        externalContextMarkdown: String
    ) throws -> String {
        guard let repo = context.repos.first(where: { $0.id == request.repoID }) else {
            throw RepoInsightArtifactError.unknownRepositoryID(request.repoID)
        }
        let topics = repo.topics.isEmpty
            ? String.l10n("agent.artifact.repoInsight.noTopics")
            : repo.topics.joined(separator: ", ")
        let external = cleanExternalContext(externalContextMarkdown)
        let externalSources: String
        if request.includeSources, !external.isEmpty {
            externalSources = """

            ### \(String.l10n("agent.artifact.common.externalSearch"))

            \(external)
            """
        } else {
            externalSources = "\n\n### \(String.l10n("agent.artifact.common.externalSearch"))\n\n- \(String.l10n("agent.artifact.common.externalUnavailable"))"
        }

        return """
        # \(request.title)

        > \(String.l10n("agent.artifact.common.userGoal")): \(prompt)
        > \(String.l10n("agent.artifact.common.repository")): [\(repo.fullName)](\(repo.htmlUrl))
        > \(String.l10n("agent.artifact.common.dataSource")): \(context.sourceDescription)
        > \(String.l10n("agent.artifact.common.snapshotTime")): \(ISO8601DateFormatter.shared.string(from: context.generatedAt))

        ## \(String.l10n("agent.artifact.common.summary"))

        \(request.summary)

        ## \(String.l10n("agent.artifact.repoInsight.repositorySnapshot"))

        - [R1] **[\(repo.fullName)](\(repo.htmlUrl))**
        - \(String.l10n("agent.artifact.common.language")): \(repo.language ?? String.l10n("agent.artifact.common.unknown"))
        - \(String.l10n("agent.artifact.common.stars")): \(repo.starsCount)
        - \(String.l10n("agent.artifact.common.description")): \(repo.description ?? String.l10n("agent.artifact.common.noDescription"))
        - \(String.l10n("agent.artifact.common.topics")): \(topics)
        - \(String.l10n("agent.artifact.common.private")): \(repo.isPrivate)

        ## \(String.l10n("agent.artifact.repoInsight.positioning"))

        \(request.positioning)

        ## \(String.l10n("agent.artifact.repoInsight.adoptionFit"))

        \(request.adoptionFit)

        ## \(String.l10n("agent.artifact.repoInsight.risks"))

        \(list(request.risks))

        ## \(String.l10n("agent.artifact.repoInsight.recommendedActions"))

        \(list(request.recommendedActions))

        ## \(String.l10n("agent.artifact.common.sources"))

        ### \(String.l10n("agent.artifact.common.localSnapshot"))

        - [R1] [\(repo.fullName)](\(repo.htmlUrl)) — \(String.l10n("agent.artifact.common.frozenMetadata"))
        \(externalSources)

        ## \(String.l10n("agent.artifact.common.limitations"))

        - \(String.l10n("agent.artifact.weekly.metadataLimitation"))
        - \(String.l10n("agent.artifact.repoInsight.evidenceLimitation"))
        \(list(request.limitations))
        """
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "- \(String.l10n("agent.artifact.common.noneReported"))" : items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func cleanExternalContext(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("<external_context") && trimmed != "</external_context>"
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension AgentJSONValue {
    var booleanValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
