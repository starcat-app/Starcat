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
            return "Invalid Repo Insight artifact arguments: \(detail)"
        case .unknownRepositoryID(let id):
            return "Repo Insight references repository \(id) outside the frozen run context"
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
        let topics = repo.topics.isEmpty ? "None in local snapshot" : repo.topics.joined(separator: ", ")
        let external = cleanExternalContext(externalContextMarkdown)
        let externalSources: String
        if request.includeSources, !external.isEmpty {
            externalSources = """

            ### External Search

            \(external)
            """
        } else {
            externalSources = "\n\n### External Search\n\n- Not used, disabled, or no verifiable results were returned."
        }

        return """
        # \(request.title)

        > User goal: \(prompt)
        > Repository: [\(repo.fullName)](\(repo.htmlUrl))
        > Data source: \(context.sourceDescription)
        > Snapshot time: \(ISO8601DateFormatter.shared.string(from: context.generatedAt))

        ## Summary

        \(request.summary)

        ## Repository Snapshot

        - [R1] **[\(repo.fullName)](\(repo.htmlUrl))**
        - Language: \(repo.language ?? "Unknown")
        - Stars: \(repo.starsCount)
        - Description: \(repo.description ?? "No description in local snapshot")
        - Topics: \(topics)
        - Private: \(repo.isPrivate)

        ## Positioning

        \(request.positioning)

        ## Adoption Fit

        \(request.adoptionFit)

        ## Risks

        \(list(request.risks))

        ## Recommended Actions

        \(list(request.recommendedActions))

        ## Sources

        ### Starcat Local Snapshot

        - [R1] [\(repo.fullName)](\(repo.htmlUrl)) — frozen repository metadata
        \(externalSources)

        ## Limitations

        - Repository metadata comes from the frozen Starcat run context, not live GitHub.
        - README, License and maintenance activity are not claimed unless present in cited evidence.
        \(list(request.limitations))
        """
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "- None reported." : items.map { "- \($0)" }.joined(separator: "\n")
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
