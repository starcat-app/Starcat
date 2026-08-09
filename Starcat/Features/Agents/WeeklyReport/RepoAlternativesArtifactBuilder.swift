//
//  RepoAlternativesArtifactBuilder.swift
//  Starcat
//
//  Repo Alternatives 的结构化 artifact 契约与确定性渲染器。
//
//  候选仓库不属于单仓冻结快照，因此必须先由 External Search 提供公开证据。宿主会
//  校验 GitHub URL、仓库全名和搜索结果的一致性，避免模型凭空生成候选仓库。
//

import Foundation

struct RepoAlternativeCandidate: Equatable, Sendable {
    var fullName: String
    var url: URL
    var positioning: String
    var adoptionFit: String
    var risks: [String]
}

struct RepoAlternativesArtifactRequest: Equatable, Sendable {
    var sourceRepoID: Int64
    var title: String
    var summary: String
    var candidates: [RepoAlternativeCandidate]
    var recommendedActions: [String]
    var limitations: [String]
    var includeSources: Bool

    init(arguments: AgentJSONValue) throws {
        guard let object = arguments.objectValue else {
            throw RepoAlternativesArtifactError.invalidArguments("root must be an object")
        }
        guard let sourceRepoID = object["sourceRepoID"]?.integerValue else {
            throw RepoAlternativesArtifactError.invalidArguments("sourceRepoID must be an integer")
        }
        self.sourceRepoID = Int64(sourceRepoID)
        self.title = try Self.requiredString("title", in: object)
        self.summary = try Self.requiredString("summary", in: object)
        self.candidates = try Self.candidates(in: object)
        self.recommendedActions = try Self.stringArray("recommendedActions", in: object)
        self.limitations = try Self.stringArray("limitations", in: object)
        self.includeSources = object["includeSources"]?.booleanValue ?? true
    }

    private static func candidates(in object: [String: AgentJSONValue]) throws -> [RepoAlternativeCandidate] {
        guard case .array(let values) = object["candidates"] else {
            throw RepoAlternativesArtifactError.invalidArguments("candidates must be an array")
        }
        guard values.count <= 6 else {
            throw RepoAlternativesArtifactError.invalidArguments("candidates must contain at most 6 repositories")
        }
        return try values.map { value in
            guard let candidate = value.objectValue else {
                throw RepoAlternativesArtifactError.invalidArguments("each candidate must be an object")
            }
            let fullName = try requiredString("fullName", in: candidate)
            let rawURL = try requiredString("url", in: candidate)
            let url = try validatedGitHubRepositoryURL(rawURL, expectedFullName: fullName)
            return RepoAlternativeCandidate(
                fullName: fullName,
                url: url,
                positioning: try requiredString("positioning", in: candidate),
                adoptionFit: try requiredString("adoptionFit", in: candidate),
                risks: try stringArray("risks", in: candidate)
            )
        }
    }

    private static func validatedGitHubRepositoryURL(
        _ rawValue: String,
        expectedFullName: String
    ) throws -> URL {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com"
        else {
            throw RepoAlternativesArtifactError.invalidArguments("candidate url must be an https://github.com repository URL")
        }
        let pathParts = components.path.split(separator: "/").map(String.init)
        guard pathParts.count == 2 else {
            throw RepoAlternativesArtifactError.invalidArguments("candidate url must point to a GitHub repository root")
        }
        let urlFullName = pathParts.joined(separator: "/")
        guard urlFullName.caseInsensitiveCompare(expectedFullName) == .orderedSame,
              let normalizedURL = URL(string: "https://github.com/\(urlFullName)")
        else {
            throw RepoAlternativesArtifactError.invalidArguments("candidate fullName must match its GitHub url")
        }
        return normalizedURL
    }

    private static func requiredString(
        _ key: String,
        in object: [String: AgentJSONValue]
    ) throws -> String {
        let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw RepoAlternativesArtifactError.invalidArguments("\(key) must be a non-empty string")
        }
        return value
    }

    private static func stringArray(
        _ key: String,
        in object: [String: AgentJSONValue]
    ) throws -> [String] {
        guard case .array(let values) = object[key] else {
            throw RepoAlternativesArtifactError.invalidArguments("\(key) must be an array")
        }
        return try values.map { value in
            let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !string.isEmpty else {
                throw RepoAlternativesArtifactError.invalidArguments("\(key) contains an empty value")
            }
            return string
        }
    }
}

enum RepoAlternativesArtifactError: LocalizedError, Equatable, Sendable {
    case invalidArguments(String)
    case unknownRepositoryID(Int64)
    case sourceRepositoryIncluded(String)
    case duplicateCandidate(String)
    case candidateWithoutExternalEvidence(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return String(
                format: String.l10n("agent.artifact.repoAlternatives.error.invalidArgumentsFormat"),
                message
            )
        case .unknownRepositoryID(let id):
            return String(
                format: String.l10n("agent.artifact.repoAlternatives.error.unknownRepositoryFormat"),
                id
            )
        case .sourceRepositoryIncluded(let fullName):
            return String(
                format: String.l10n("agent.artifact.repoAlternatives.error.sourceIncludedFormat"),
                fullName
            )
        case .duplicateCandidate(let fullName):
            return String(
                format: String.l10n("agent.artifact.repoAlternatives.error.duplicateCandidateFormat"),
                fullName
            )
        case .candidateWithoutExternalEvidence(let fullName):
            return String(
                format: String.l10n("agent.artifact.repoAlternatives.error.missingExternalEvidenceFormat"),
                fullName
            )
        }
    }
}

enum RepoAlternativesArtifactBuilder {
    static func build(
        request: RepoAlternativesArtifactRequest,
        prompt: String,
        context: AgentRunContext,
        externalContextMarkdown: String
    ) throws -> String {
        guard let sourceRepo = context.repos.first(where: { $0.id == request.sourceRepoID }) else {
            throw RepoAlternativesArtifactError.unknownRepositoryID(request.sourceRepoID)
        }
        try validateCandidates(
            request.candidates,
            sourceRepo: sourceRepo,
            externalContextMarkdown: externalContextMarkdown
        )

        let topics = sourceRepo.topics.isEmpty
            ? String.l10n("agent.artifact.repoInsight.noTopics")
            : sourceRepo.topics.joined(separator: ", ")
        let comparison = comparisonMarkdown(request.candidates)
        let external = cleanedExternalContext(externalContextMarkdown)
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
        > \(String.l10n("agent.artifact.common.repository")): [\(sourceRepo.fullName)](\(sourceRepo.htmlUrl))
        > \(String.l10n("agent.artifact.common.dataSource")): \(context.sourceDescription)
        > \(String.l10n("agent.artifact.common.snapshotTime")): \(ISO8601DateFormatter.shared.string(from: context.generatedAt))

        ## \(String.l10n("agent.artifact.common.summary"))

        \(request.summary)

        ## \(String.l10n("agent.artifact.repoInsight.repositorySnapshot"))

        - [R1] **[\(sourceRepo.fullName)](\(sourceRepo.htmlUrl))**
        - \(String.l10n("agent.artifact.common.language")): \(sourceRepo.language ?? String.l10n("agent.artifact.common.unknown"))
        - \(String.l10n("agent.artifact.common.stars")): \(sourceRepo.starsCount)
        - \(String.l10n("agent.artifact.common.description")): \(sourceRepo.description ?? String.l10n("agent.artifact.common.noDescription"))
        - \(String.l10n("agent.artifact.common.topics")): \(topics)

        ## \(String.l10n("agent.definition.repoAlternatives.title"))

        \(comparison)

        ## \(String.l10n("agent.artifact.repoInsight.recommendedActions"))

        \(list(request.recommendedActions))

        ## \(String.l10n("agent.artifact.common.sources"))

        ### \(String.l10n("agent.artifact.common.localSnapshot"))

        - [R1] [\(sourceRepo.fullName)](\(sourceRepo.htmlUrl)) — \(String.l10n("agent.artifact.common.frozenMetadata"))
        \(externalSources)

        ## \(String.l10n("agent.artifact.common.limitations"))

        - \(String.l10n("agent.artifact.weekly.metadataLimitation"))
        - \(String.l10n("agent.artifact.repoInsight.evidenceLimitation"))
        \(list(request.limitations))
        """
    }

    private static func validateCandidates(
        _ candidates: [RepoAlternativeCandidate],
        sourceRepo: AgentRepoSnapshot,
        externalContextMarkdown: String
    ) throws {
        var seen: Set<String> = []
        for candidate in candidates {
            let normalizedName = candidate.fullName.lowercased()
            guard normalizedName != sourceRepo.fullName.lowercased() else {
                throw RepoAlternativesArtifactError.sourceRepositoryIncluded(candidate.fullName)
            }
            guard seen.insert(normalizedName).inserted else {
                throw RepoAlternativesArtifactError.duplicateCandidate(candidate.fullName)
            }
            // 候选不在单仓冻结快照内；只有搜索返回内容确实出现仓库名或规范 URL 时才准入。
            guard externalContextMarkdown.localizedCaseInsensitiveContains(candidate.fullName)
                    || externalContextMarkdown.localizedCaseInsensitiveContains(candidate.url.absoluteString)
            else {
                throw RepoAlternativesArtifactError.candidateWithoutExternalEvidence(candidate.fullName)
            }
        }
    }

    private static func comparisonMarkdown(_ candidates: [RepoAlternativeCandidate]) -> String {
        guard !candidates.isEmpty else {
            return "- \(String.l10n("agent.artifact.common.noneReported"))"
        }
        let header = "| \(String.l10n("agent.artifact.common.repository")) | \(String.l10n("agent.artifact.repoInsight.positioning")) | \(String.l10n("agent.artifact.repoInsight.adoptionFit")) | \(String.l10n("agent.artifact.repoInsight.risks")) |"
        let separator = "| --- | --- | --- | --- |"
        let rows = candidates.map { candidate in
            let risks = candidate.risks.isEmpty
                ? String.l10n("agent.artifact.common.noneReported")
                : candidate.risks.joined(separator: "<br>")
            return "| [\(escape(candidate.fullName))](\(candidate.url.absoluteString)) | \(escape(candidate.positioning)) | \(escape(candidate.adoptionFit)) | \(escape(risks)) |"
        }
        return ([header, separator] + rows).joined(separator: "\n")
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "- \(String.l10n("agent.artifact.common.noneReported"))" : items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func cleanedExternalContext(_ markdown: String) -> String {
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
