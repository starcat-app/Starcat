//
//  UntaggedTidyAgentTools.swift
//  Starcat
//
//  Untagged Tidy 的 Agent Tool adapter。
//
//  模型先读取现有 taxonomy，再提交 dry-run diff；真正写入工具声明
//  `requiresConfirmation`，由 Loop Runtime 持久化审批并在用户批准后执行。
//

import Foundation

enum UntaggedTidyAgentTools {
    static func make(executor: any RepositoryTagCapabilityExecuting) -> [any AgentTool] {
        [
            InspectTool(executor: executor),
            PreviewTool(executor: executor),
            ApplyTool(executor: executor)
        ]
    }

    struct InspectTool: AgentTool {
        let executor: any RepositoryTagCapabilityExecuting
        let definition = readOnlyDefinition(
            name: "tag_inspect_untagged",
            description: "Inspect explicitly selected local repositories, their current tags, and the existing Starcat tag taxonomy.",
            properties: [:]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            do {
                let repoIDs = input.context.repos.map(\.id)
                let inspection = try await executor.inspect(
                    repoIDs: repoIDs,
                    allowedRepoIDs: Set(repoIDs)
                )
                let repos = inspection.repositories.map { repo in
                    let current = inspection.currentTagsByRepoID[repo.id, default: []].map(\.name)
                    return "- id=\(repo.id) | \(repo.fullName) | current_tags=\(current)"
                }.joined(separator: "\n")
                let tags = inspection.availableTags.map { "- id=\($0.id) | name=\($0.name)" }
                    .joined(separator: "\n")
                return completedResult(
                    toolName: id,
                    summary: "\(inspection.repositories.count) repos / \(inspection.availableTags.count) tags",
                    input: input.context.sourceDescription,
                    output: """
                    repositories:
                    \(repos)

                    existing_taxonomy:
                    \(tags)
                    """
                )
            } catch {
                return failedResult(
                    toolName: id,
                    input: input.context.sourceDescription,
                    message: localizedMessage(for: error)
                )
            }
        }
    }

    struct PreviewTool: AgentTool {
        let executor: any RepositoryTagCapabilityExecuting
        let definition = readOnlyDefinition(
            name: "tag_preview_untagged",
            description: "Validate existing-tag suggestions for the frozen repository scope and return a deterministic dry-run preview hash.",
            properties: assignmentProperties,
            required: ["assignments"]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            do {
                let assignments = try parseAssignments(input.arguments)
                let preview = try await executor.preview(
                    assignments: assignments,
                    allowedRepoIDs: Set(input.context.repos.map(\.id))
                )
                return completedResult(
                    toolName: id,
                    summary: "\(preview.assignments.count) repos",
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    output: previewOutput(preview, context: input.context)
                )
            } catch {
                return failedResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: localizedMessage(for: error)
                )
            }
        }
    }

    struct ApplyTool: AgentTool {
        let executor: any RepositoryTagCapabilityExecuting
        let definition = AgentToolDefinition(
            name: "tag_apply_untagged",
            description: "Apply the exact previously previewed tag diff, then read back every repository assignment. Requires explicit user confirmation.",
            inputSchema: AgentJSONSchema(
                type: .object,
                properties: assignmentProperties.merging([
                    "previewHash": AgentJSONSchema(
                        type: .string,
                        description: "Exact preview_hash returned by tag_preview_untagged"
                    )
                ]) { current, _ in current },
                required: ["assignments", "previewHash"]
            ),
            permission: .requiresConfirmation,
            completesRun: true,
            timeoutMilliseconds: 30_000,
            retryPolicy: .none
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            do {
                let assignments = try parseAssignments(input.arguments)
                let previewHash = input.arguments.objectValue?["previewHash"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !previewHash.isEmpty else {
                    throw UntaggedTidyToolError.missingPreviewHash
                }
                let result = try await executor.apply(
                    assignments: assignments,
                    expectedPreviewHash: previewHash,
                    allowedRepoIDs: Set(input.context.repos.map(\.id))
                )
                let markdown = artifact(result: result, prompt: input.prompt, context: input.context)
                let sources = input.context.repos.map {
                    AgentToolResultSource(title: $0.fullName, url: $0.htmlUrl, provider: "Starcat")
                }
                return completedResult(
                    toolName: id,
                    summary: "\(result.preview.assignments.count) repos",
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    output: String(markdown.prefix(1_200)),
                    payload: .markdown(markdown),
                    sources: sources
                )
            } catch {
                return failedResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: localizedMessage(for: error)
                )
            }
        }
    }

    private static let assignmentSchema = AgentJSONSchema(
        type: .object,
        properties: [
            "repoID": AgentJSONSchema(type: .integer, description: "Repository ID from the frozen explicit scope"),
            "tagNames": AgentJSONSchema(
                type: .array,
                description: "One to eight existing Starcat tag names",
                items: AgentJSONSchema(type: .string)
            )
        ],
        required: ["repoID", "tagNames"]
    )

    private static let assignmentProperties: [String: AgentJSONSchema] = [
        "assignments": AgentJSONSchema(
            type: .array,
            description: "Complete dry-run diff for explicitly selected repositories",
            items: assignmentSchema
        )
    ]

    private static func parseAssignments(_ arguments: AgentJSONValue) throws -> [RepositoryTagAssignment] {
        guard let object = arguments.objectValue,
              case .array(let values) = object["assignments"]
        else {
            throw UntaggedTidyToolError.invalidAssignments
        }
        return try values.map { value in
            guard let assignment = value.objectValue,
                  let repoID = assignment["repoID"]?.integerValue,
                  case .array(let tagValues) = assignment["tagNames"]
            else {
                throw UntaggedTidyToolError.invalidAssignments
            }
            let tagNames = try tagValues.map { tagValue -> String in
                guard let tagName = tagValue.stringValue else {
                    throw UntaggedTidyToolError.invalidAssignments
                }
                return tagName
            }
            return RepositoryTagAssignment(repoID: Int64(repoID), tagNames: tagNames)
        }
    }

    private static func previewOutput(
        _ preview: RepositoryTagPreview,
        context: AgentRunContext
    ) -> String {
        let reposByID = Dictionary(uniqueKeysWithValues: context.repos.map { ($0.id, $0) })
        let diff = preview.assignments.map { assignment in
            let name = reposByID[assignment.repoID]?.fullName ?? String(assignment.repoID)
            return "- \(name): [] -> [\(assignment.tagNames.joined(separator: ", "))]"
        }.joined(separator: "\n")
        return """
        dry_run: true
        preview_hash: \(preview.previewHash)
        changes:
        \(diff)
        """
    }

    private static func artifact(
        result: RepositoryTagApplyResult,
        prompt: String,
        context: AgentRunContext
    ) -> String {
        let reposByID = Dictionary(uniqueKeysWithValues: context.repos.map { ($0.id, $0) })
        let rows = result.preview.assignments.map { assignment in
            let repo = reposByID[assignment.repoID]
            let repoLabel = repo.map { "[\($0.fullName)](\($0.htmlUrl))" } ?? String(assignment.repoID)
            let verified = result.verifiedTagNamesByRepoID[assignment.repoID, default: []]
            return "- \(repoLabel): \(verified.joined(separator: ", "))"
        }.joined(separator: "\n")
        return """
        # \(String.l10n("agent.definition.untaggedTidy.title"))

        > \(String.l10n("agent.artifact.common.userGoal")): \(prompt)
        > \(String.l10n("agent.artifact.common.dataSource")): \(context.sourceDescription)
        > preview_hash: \(result.preview.previewHash)

        ## \(String.l10n("agent.artifact.common.summary"))

        \(rows)

        ## \(String.l10n("agent.artifact.common.sources"))

        - \(String.l10n("agent.artifact.common.localSnapshot"))
        - read-back: \(String.l10n("agent.tool.status.completed"))
        """
    }

    private static func readOnlyDefinition(
        name: String,
        description: String,
        properties: [String: AgentJSONSchema],
        required: [String] = []
    ) -> AgentToolDefinition {
        AgentToolDefinition(
            name: name,
            description: description,
            inputSchema: AgentJSONSchema(type: .object, properties: properties, required: required),
            permission: .readOnly,
            timeoutMilliseconds: 30_000,
            retryPolicy: .none
        )
    }

    private static func completedResult(
        toolName: String,
        summary: String,
        input: String,
        output: String,
        payload: AgentToolPayload = .none,
        sources: [AgentToolResultSource] = []
    ) -> AgentToolResult {
        let completed = String.l10n("agent.tool.status.completed")
        let toolOutput = AgentToolOutput(
            toolName: toolName,
            summary: summary,
            detail: output,
            input: input,
            output: output,
            log: completed
        )
        return AgentToolResult(
            output: toolOutput,
            trace: AgentTraceSpan(
                kind: String.l10n("agent.trace.kind.tool"),
                title: toolName,
                summary: summary,
                input: input,
                output: output,
                log: completed,
                relatedToolOutputID: toolOutput.id
            ),
            payload: payload,
            sources: sources
        )
    }

    private static func failedResult(
        toolName: String,
        input: String,
        message: String
    ) -> AgentToolResult {
        let output = AgentToolOutput(
            toolName: toolName,
            summary: String.l10n("agent.tool.status.failed"),
            detail: message,
            input: input,
            output: "error: \(message)",
            log: message
        )
        return AgentToolResult(
            status: .failed,
            output: output,
            trace: AgentTraceSpan(
                kind: String.l10n("agent.trace.kind.tool"),
                title: toolName,
                summary: output.summary,
                input: input,
                output: output.output,
                log: message,
                status: .failed,
                relatedToolOutputID: output.id
            )
        )
    }

    /// Capability 保留稳定技术错误；Agent adapter 负责把最终可见文案映射到完整 i18n key。
    private static func localizedMessage(for error: Error) -> String {
        switch error {
        case RepositoryTagCapabilityError.repositoryAlreadyTagged(_):
            return String.l10n("agent.untaggedTidy.error.alreadyTagged")
        case RepositoryTagCapabilityError.emptyTags(_),
             RepositoryTagCapabilityError.tooManyTags(_),
             RepositoryTagCapabilityError.tagNotFound(_):
            return String.l10n("agent.untaggedTidy.error.invalidTaxonomy")
        case RepositoryTagCapabilityError.previewChanged:
            return String.l10n("agent.untaggedTidy.error.previewChanged")
        case RepositoryTagCapabilityError.readBackMismatch(_):
            return String.l10n("agent.untaggedTidy.error.verificationFailed")
        case is RepositoryTagCapabilityError:
            return String.l10n("agent.untaggedTidy.error.invalidScope")
        case is UntaggedTidyToolError:
            return String.l10n("agent.untaggedTidy.error.invalidArguments")
        default:
            return String.l10n("agent.untaggedTidy.error.operationFailed")
        }
    }
}

private enum UntaggedTidyToolError: LocalizedError {
    case invalidAssignments
    case missingPreviewHash

    var errorDescription: String? {
        switch self {
        case .invalidAssignments: return "assignments must contain repoID and tagNames."
        case .missingPreviewHash: return "previewHash must match tag_preview_untagged output."
        }
    }
}
