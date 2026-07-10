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
