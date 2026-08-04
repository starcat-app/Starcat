//
//  AgentPromptBuilderTests.swift
//  StarcatTests
//
//  Agent Prompt Pipeline、上下文预算和消息压缩测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Agent Prompt Builder")
struct AgentPromptBuilderTests {

    @Test("不同 execution mode 注入不同安全边界")
    func modeGuardrails() {
        let builder = AgentPromptBuilder()
        let context = promptContext()

        let planning = builder.buildSystemPrompt(
            environment: environment(mode: .readonlyPlanning),
            context: context
        )
        let action = builder.buildSystemPrompt(
            environment: environment(mode: .approvedAction),
            context: context
        )

        #expect(planning.contains("Plan and inspect only"))
        #expect(action.contains("must wait for explicit user approval"))
    }

    @Test("preferred language、搜索策略和可见工具进入 system prompt")
    func languageSearchAndToolVisibility() {
        var context = promptContext()
        context.preferredLanguage = "Simplified Chinese"
        context.externalSearch = AgentExternalSearchPolicy(
            isEnabled: false,
            provider: "automatic",
            allowsPrivateRepositories: false,
            aggregatesProviders: false
        )
        context.availableTools = [
            AgentPromptToolSummary(
                name: "external_search",
                description: "Search public web sources",
                permission: .readOnly
            )
        ]

        let prompt = AgentPromptBuilder().buildSystemPrompt(
            environment: environment(mode: .reportGeneration),
            context: context
        )

        #expect(prompt.contains("Simplified Chinese"))
        #expect(prompt.contains("enabled: false"))
        #expect(prompt.contains("external_search [readOnly]"))
        #expect(prompt.contains("Do not send private repository metadata"))
    }

    @Test("repo snapshot 遵守数量和描述长度预算")
    func repositoryBudget() {
        let budgeter = AgentContextBudgeter(budget: AgentContextBudget(
            maxRepositories: 1,
            maxRepositoryDescriptionCharacters: 28,
            maxUserInputCharacters: 100,
            maxExternalContextCharacters: 100,
            maxToolResultCharacters: 100,
            maxMessageCharacters: 1_000
        ))
        let context = AgentRunContext(
            sourceDescription: "Unit",
            repos: [repo(id: 1, description: String(repeating: "a", count: 100)), repo(id: 2, description: "second")]
        )

        let block = budgeter.repositorySnapshotBlock(context)

        #expect(block.contains("owner/repo-1"))
        #expect(!block.contains("owner/repo-2"))
        #expect(block.contains("1 repositories omitted"))
        #expect(block.contains("truncated by Agent context budget"))
        #expect(block.contains("id=1"))
        #expect(block.contains("private=false"))
    }

    @Test("文本附件按数量和字符预算进入首轮 prompt")
    func attachmentBudget() {
        let budgeter = AgentContextBudgeter(budget: AgentContextBudget(
            maxRepositories: 1,
            maxRepositoryDescriptionCharacters: 28,
            maxUserInputCharacters: 100,
            maxExternalContextCharacters: 100,
            maxAttachmentCount: 1,
            maxAttachmentCharacters: 60,
            maxToolResultCharacters: 100,
            maxMessageCharacters: 1_000
        ))
        let context = AgentRunContext(
            sourceDescription: "Unit",
            attachments: [
                AgentPromptAttachment(name: "requirements.md", content: String(repeating: "a", count: 200)),
                AgentPromptAttachment(name: "ignored.txt", content: "ignored")
            ]
        )

        let block = budgeter.attachmentSnapshotBlock(context)

        #expect(block.contains("requirements.md"))
        #expect(block.contains("truncated by Agent context budget"))
        #expect(block.contains("1 attachments omitted"))
        #expect(!block.contains("ignored.txt"))
    }

    @Test("首轮 prompt 明示冻结的仓库范围模式与显式 ID")
    func frozenScopeMetadataEntersFirstTurnPrompt() {
        var context = promptContext()
        context.runContext = AgentRunContext(
            sourceDescription: "Unit",
            explicitRepos: [AIComposerRepoReference(
                id: 42,
                owner: "groue",
                name: "GRDB.swift",
                fullName: "groue/GRDB.swift",
                language: "Swift",
                starsCount: 8_000
            )],
            explicitRepoMode: .exclude
        )

        let request = AgentPromptBuilder().buildTurnRequest(
            userInput: "排除 GRDB",
            messages: [],
            environment: environment(mode: .reportGeneration),
            context: context
        )

        #expect(request.userPrompt.contains("explicit_repo_mode: exclude"))
        #expect(request.userPrompt.contains("explicit_repo_ids: [42]"))
    }

    @Test("消息压缩保留首个目标和最近完整 tool turn")
    func compactsMessagesByTurn() {
        let runID = UUID()
        let first = AgentMessage(
            runID: runID,
            role: .user,
            turn: 0,
            sequence: 1,
            parts: [.text("original goal")]
        )
        let middle = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 1,
            sequence: 2,
            parts: [.text(String(repeating: "m", count: 2_000))]
        )
        let call = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 2,
            sequence: 3,
            parts: [.toolCall(AgentToolCall(
                id: "call-1",
                name: "external_search",
                input: .object(["query": .string("Swift")]),
                sequence: 4
            ))]
        )
        let result = AgentMessage(
            runID: runID,
            role: .tool,
            turn: 2,
            sequence: 5,
            parts: [.toolResult(AgentToolResultMessage(
                toolCallID: "call-1",
                toolName: "external_search",
                output: .string("done"),
                isError: false,
                status: .completed,
                sequence: 6
            ))]
        )

        let compacted = AgentMessageCompactor(maxCharacters: 1_400)
            .compact([first, middle, call, result])

        #expect(compacted.map(\.id).contains(first.id))
        #expect(!compacted.map(\.id).contains(middle.id))
        #expect(compacted.map(\.id).contains(call.id))
        #expect(compacted.map(\.id).contains(result.id))
    }

    @Test("超大 tool-result 只在模型副本中截断并保留调用关联")
    func compactsLargeToolResultWithoutBreakingCorrelation() throws {
        let runID = UUID()
        let first = AgentMessage(
            runID: runID,
            role: .user,
            turn: 0,
            sequence: 0,
            parts: [.text("goal")]
        )
        let call = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 1,
            sequence: 1,
            parts: [.toolCall(AgentToolCall(
                id: "call-large",
                name: "knowledge_search",
                input: .object(["query": .string("Swift")]),
                sequence: 0
            ))]
        )
        let originalOutput = String(repeating: "source", count: 2_000)
        let result = AgentMessage(
            runID: runID,
            role: .tool,
            turn: 1,
            sequence: 2,
            parts: [.toolResult(AgentToolResultMessage(
                toolCallID: "call-large",
                toolName: "knowledge_search",
                output: .object(["detail": .string(originalOutput)]),
                isError: false,
                status: .completed,
                toolAudit: .knowledge(AgentKnowledgeRetrievalAudit(
                    scopeMode: .only,
                    frozenRepoIDs: [1],
                    explicitRepoIDs: [1],
                    evidenceBlockCount: 1,
                    citations: [],
                    retrievalTrace: RAGRetrievalTrace(candidates: [
                        RAGRetrievalCandidateTrace(repoID: 1, fullName: "octo/demo")
                    ]),
                    diagnostics: nil,
                    limitations: []
                )),
                sequence: 0
            ))]
        )

        let compacted = AgentMessageCompactor(
            maxCharacters: 1_500,
            maxToolResultCharacters: 400,
            maxExternalContextCharacters: 400
        ).compact([first, call, result])

        #expect(compacted.map(\.id) == [first.id, call.id, result.id])
        let compactedResult = try #require(compacted.last?.parts.compactMap { part -> AgentToolResultMessage? in
            guard case .toolResult(let result) = part else { return nil }
            return result
        }.first)
        #expect(compactedResult.output.objectValue?["truncated"] == .bool(true))
        #expect(compactedResult.toolAudit?.knowledgeRetrieval?.frozenRepoIDs == [1])
        #expect(try compactedResult.output.jsonString().contains("truncated by Agent message budget"))
        #expect(result.parts.first != compacted.last?.parts.first)
        try AgentMessageContract.validate(compacted)
    }

    private func environment(mode: AgentExecutionMode) -> AgentPromptEnvironment {
        AgentPromptEnvironment(
            appName: "Starcat",
            appVersion: "1.0",
            platform: "macOS",
            currentDate: Date(timeIntervalSince1970: 1_788_000_000),
            localeIdentifier: "zh-Hans",
            workspaceName: "Unit Library",
            mode: mode
        )
    }

    private func promptContext() -> AgentPromptContext {
        AgentPromptContext(
            definition: BuiltInAgents.githubWeeklyReport,
            runContext: AgentRunContext(sourceDescription: "Unit"),
            availableTools: [],
            rules: [],
            preferredLanguage: "English",
            externalSearch: AgentExternalSearchPolicy(
                isEnabled: true,
                provider: "automatic",
                allowsPrivateRepositories: false,
                aggregatesProviders: false
            )
        )
    }

    private func repo(id: Int64, description: String) -> AgentRepoSnapshot {
        AgentRepoSnapshot(
            id: id,
            owner: "owner",
            name: "repo-\(id)",
            fullName: "owner/repo-\(id)",
            description: description,
            language: "Swift",
            starsCount: 10,
            topics: ["agent"],
            isPrivate: false,
            isStarred: true,
            starredAt: nil,
            htmlUrl: "https://github.com/owner/repo-\(id)"
        )
    }
}
