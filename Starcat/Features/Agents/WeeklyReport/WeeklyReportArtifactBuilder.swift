//
//  WeeklyReportArtifactBuilder.swift
//  Starcat
//
//  GitHub Weekly Report 的结构化 artifact 契约与确定性渲染器。
//
//  模型负责提交摘要、主题分析和引用的 repo IDs；宿主只接受当前 run 冻结快照中的
//  仓库，并用真实 URL/Stars/Topics 渲染引用。这样既保留 LLM 的分析能力，也不会让
//  模型伪造仓库事实或把未审计的 Markdown 直接当最终产物。
//

import Foundation

struct WeeklyReportArtifactRequest: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        var heading: String
        var analysis: String
        var repoIDs: [Int64]
    }

    var title: String
    var executiveSummary: String
    var sections: [Section]
    var limitations: [String]
    var includeSources: Bool

    init(arguments: AgentJSONValue) throws {
        guard let object = arguments.objectValue else {
            throw WeeklyReportArtifactError.invalidArguments("root must be an object")
        }
        self.title = try Self.requiredString("title", in: object)
        self.executiveSummary = try Self.requiredString("executiveSummary", in: object)
        self.sections = try Self.sections(in: object)
        self.limitations = try Self.stringArray("limitations", in: object)
        self.includeSources = object["includeSources"]?.boolValue ?? true

        guard !sections.isEmpty else { throw WeeklyReportArtifactError.emptySections }
        guard sections.allSatisfy({ !$0.repoIDs.isEmpty }) else {
            throw WeeklyReportArtifactError.sectionWithoutRepositories
        }
    }

    private static func sections(in object: [String: AgentJSONValue]) throws -> [Section] {
        guard case .array(let values) = object["sections"] else {
            throw WeeklyReportArtifactError.invalidArguments("sections must be an array")
        }
        return try values.map { value in
            guard let section = value.objectValue else {
                throw WeeklyReportArtifactError.invalidArguments("section must be an object")
            }
            let repoIDs = try integerArray("repoIDs", in: section).map(Int64.init)
            return Section(
                heading: try requiredString("heading", in: section),
                analysis: try requiredString("analysis", in: section),
                repoIDs: repoIDs
            )
        }
    }

    private static func requiredString(
        _ key: String,
        in object: [String: AgentJSONValue]
    ) throws -> String {
        let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw WeeklyReportArtifactError.invalidArguments("\(key) must be a non-empty string")
        }
        return value
    }

    private static func stringArray(
        _ key: String,
        in object: [String: AgentJSONValue]
    ) throws -> [String] {
        guard case .array(let values) = object[key] else {
            throw WeeklyReportArtifactError.invalidArguments("\(key) must be an array")
        }
        return try values.map { value in
            let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !string.isEmpty else {
                throw WeeklyReportArtifactError.invalidArguments("\(key) contains an empty value")
            }
            return string
        }
    }

    private static func integerArray(
        _ key: String,
        in object: [String: AgentJSONValue]
    ) throws -> [Int] {
        guard case .array(let values) = object[key] else {
            throw WeeklyReportArtifactError.invalidArguments("\(key) must be an array")
        }
        return try values.map { value in
            guard let integer = value.integerValue else {
                throw WeeklyReportArtifactError.invalidArguments("\(key) contains a non-integer value")
            }
            return integer
        }
    }
}

enum WeeklyReportArtifactError: LocalizedError, Equatable, Sendable {
    case invalidArguments(String)
    case emptySections
    case sectionWithoutRepositories
    case unknownRepositoryIDs([Int64])

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail):
            return "Invalid weekly report artifact arguments: \(detail)"
        case .emptySections:
            return "Weekly report artifact requires at least one section"
        case .sectionWithoutRepositories:
            return "Every weekly report section must reference at least one repository"
        case .unknownRepositoryIDs(let ids):
            return "Weekly report references repositories outside the frozen run context: \(ids.map(String.init).joined(separator: ", "))"
        }
    }
}

enum WeeklyReportArtifactBuilder {
    static func build(
        request: WeeklyReportArtifactRequest,
        prompt: String,
        context: AgentRunContext,
        externalContextMarkdown: String
    ) throws -> String {
        let reposByID = Dictionary(uniqueKeysWithValues: context.repos.map { ($0.id, $0) })
        let referencedIDs = request.sections.flatMap(\.repoIDs).uniqued()
        let unknownIDs = referencedIDs.filter { reposByID[$0] == nil }
        guard unknownIDs.isEmpty else {
            throw WeeklyReportArtifactError.unknownRepositoryIDs(unknownIDs)
        }

        let references = Dictionary(uniqueKeysWithValues: referencedIDs.enumerated().map { index, id in
            (id, "R\(index + 1)")
        })
        // 显式固定为 String，避免同模块的 GRDB.SQL 字符串插值参与泛型推断，
        // 否则最终 Markdown 会意外写入 SQL(elements: ...) 的调试描述。
        let sectionMarkdown: String = request.sections.enumerated().map { index, section -> String in
            let repoLines = section.repoIDs.compactMap { id -> String? in
                guard let repo = reposByID[id], let reference = references[id] else { return nil }
                return repoLine(repo, reference: reference)
            }
            return """
            ## \(index + 1). \(section.heading)

            \(section.analysis)

            \(repoLines.joined(separator: "\n"))
            """
        }.joined(separator: "\n\n")

        let localSources = referencedIDs.compactMap { id -> String? in
            guard let repo = reposByID[id], let reference = references[id] else { return nil }
            return "- [\(reference)] [\(repo.fullName)](\(repo.htmlUrl)) — Starcat frozen repository snapshot"
        }.joined(separator: "\n")
        let externalSources = cleanedExternalContext(externalContextMarkdown)
        let externalSection: String
        if request.includeSources, !externalSources.isEmpty {
            externalSection = """

            ### External Search

            \(externalSources)
            """
        } else {
            externalSection = "\n\n### External Search\n\n- Not used, disabled, or no verifiable results were returned."
        }
        let modelLimitations = request.limitations.map { "- \($0)" }.joined(separator: "\n")

        return """
        # \(request.title)

        > User goal: \(prompt)
        > Scope: \(referencedIDs.count) repositories from \(context.sourceDescription)
        > Snapshot time: \(ISO8601DateFormatter.shared.string(from: context.generatedAt))

        ## Overview

        \(request.executiveSummary)

        \(sectionMarkdown)

        ## Sources

        ### Starcat Local Snapshot

        \(localSources)
        \(externalSection)

        ## Limitations

        - Repository metadata comes from the frozen Starcat run context, not live GitHub.
        - Stars, descriptions and topics may have changed after the snapshot time.
        \(modelLimitations)
        """
    }

    private static func repoLine(_ repo: AgentRepoSnapshot, reference: String) -> String {
        let description = nonEmpty(repo.description) ?? "No description in the local snapshot."
        let topics = repo.topics.prefix(5).joined(separator: ", ")
        let topicSuffix = topics.isEmpty ? "" : " Topics: \(topics)."
        return "- [\(reference)] **[\(repo.fullName)](\(repo.htmlUrl))** — \(repo.starsCount) stars; \(description)\(topicSuffix)"
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

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension AgentJSONValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
