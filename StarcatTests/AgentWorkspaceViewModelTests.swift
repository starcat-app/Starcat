//
//  AgentWorkspaceViewModelTests.swift
//  StarcatTests
//
//  Agent Workspace ViewModel 的事件消费测试。
//
//  这些测试不验证 SwiftUI 布局,只锁住 ViewModel 对 AgentRunEvent 的状态投影。
//  这样后续 runtime 从本地只读工具切换到模型 tool-calling 时,工作台仍能依赖
//  同一组 message / approval / artifact 事实状态。
//

import Foundation
import SwiftUI
import Testing
@testable import Starcat

@MainActor
@Suite("AgentWorkspaceViewModel")
struct AgentWorkspaceViewModelTests {

    @Test("Weekly 可用默认指令和自动时间窗发送，但必须先选择有效模型")
    func weeklySubmissionValidationUsesWorkflowPolicy() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        #expect(!viewModel.canSubmit)

        configureRunnable(viewModel)

        #expect(viewModel.prompt.isEmpty)
        #expect(viewModel.selectedRepoContexts.isEmpty)
        #expect(viewModel.canSubmit)
    }

    @Test("Repo Insight 必须且只能选择一个仓库")
    func repoInsightSubmissionRequiresSingleRepository() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.repoInsight])
        configureRunnable(viewModel)
        #expect(!viewModel.canSubmit)

        let first = AIComposerRepoReference(
            id: 1,
            owner: "octo",
            name: "one",
            fullName: "octo/one",
            language: "Swift",
            starsCount: 1
        )
        let second = AIComposerRepoReference(
            id: 2,
            owner: "octo",
            name: "two",
            fullName: "octo/two",
            language: "Swift",
            starsCount: 2
        )
        viewModel.selectedRepoContexts = [first]
        #expect(viewModel.canSubmit)
        viewModel.selectedRepoContexts = [first, second]
        #expect(!viewModel.canSubmit)
    }

    @Test("Untagged Tidy 必须明确选择一到三十个仓库")
    func untaggedTidySubmissionRequiresExplicitSelection() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.untaggedTidy])
        configureRunnable(viewModel)
        #expect(!viewModel.canSubmit)

        viewModel.selectedRepoContexts = [AIComposerRepoReference(
            id: 1,
            owner: "octo",
            name: "one",
            fullName: "octo/one",
            language: "Swift",
            starsCount: 1
        )]
        #expect(viewModel.canSubmit)

        viewModel.selectedRepoContexts = (1...31).map { id in
            AIComposerRepoReference(
                id: Int64(id),
                owner: "octo",
                name: "repo-\(id)",
                fullName: "octo/repo-\(id)",
                language: "Swift",
                starsCount: id
            )
        }
        #expect(!viewModel.canSubmit)
    }

    @Test("Weekly 仓库选择器保持打开并支持连续多选")
    func weeklyRepositoryPickerStaysOpenForMultipleSelections() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        let first = mentionCandidate(id: 1, fullName: "octo/one")
        let second = mentionCandidate(id: 2, fullName: "octo/two")
        viewModel.mentionCandidates = [first, second]

        viewModel.presentContextPicker()
        viewModel.toggleRepoContext(first)
        viewModel.toggleRepoContext(second)

        #expect(viewModel.isContextPickerPresented)
        #expect(viewModel.selectedRepoContexts.map(\.id) == [1, 2])
        #expect(viewModel.displayedMentionCandidates.map(\.id) == [1, 2])
    }

    @Test("@ 作为命令打开仓库选择器且不修改正文")
    func mentionCommandOpensPickerWithoutMutatingPrompt() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        viewModel.prompt = "生成周刊"

        let handled = viewModel.handleMentionTrigger()

        #expect(handled)
        #expect(viewModel.prompt == "生成周刊")
        #expect(viewModel.contextPickerQuery.isEmpty)
        #expect(viewModel.isContextPickerPresented)
    }

    @Test("Composer 仅在非输入法组合态识别 @ 命令")
    func composerRoutesStandaloneMentionTrigger() {
        #expect(AICommandTextEditor.shouldRouteMentionTrigger(characters: "@", hasMarkedText: false))
        #expect(!AICommandTextEditor.shouldRouteMentionTrigger(characters: "@", hasMarkedText: true))
        #expect(!AICommandTextEditor.shouldRouteMentionTrigger(characters: "a", hasMarkedText: false))
    }

    @Test("仓库选择器将已选仓库置顶并支持一键清空")
    func repositoryPickerPinsAndClearsSelectedRepositories() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        let selected = mentionCandidate(id: 1, fullName: "octo/selected")
        let filteredMatch = mentionCandidate(id: 2, fullName: "redis/redis")
        viewModel.mentionCandidates = [selected]
        viewModel.toggleRepoContext(selected)
        viewModel.mentionCandidates = [filteredMatch]

        #expect(viewModel.displayedMentionCandidates.map(\.id) == [1, 2])

        viewModel.clearSelectedRepoContexts()

        #expect(viewModel.selectedRepoContexts.isEmpty)
        #expect(viewModel.displayedMentionCandidates.map(\.id) == [2])
    }

    @Test("仓库筛选重置会同时清空多选来源")
    func repositoryPickerResetClearsSelectedSources() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        viewModel.selectedRepositorySources = [.weekly, .discovery]
        viewModel.repositoryPickerFilters.star = .unstarred

        viewModel.resetRepositoryPickerFilters()

        #expect(viewModel.selectedRepositorySources.isEmpty)
        #expect(viewModel.repositoryPickerFilters == .empty)
    }

    @Test("6,000+ 多来源目录的面板、选择和清空不会重复派生全量筛选")
    func repositoryPickerLightweightInteractionsReuseFullCatalogDerivation() async throws {
        let candidates = (1...6_500).map { agentRepositoryCandidate(id: Int64($0)) }
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        viewModel.configureRepositoryCatalog(FixedWorkspaceAgentRepositoryCatalog(candidates: candidates))
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            viewModel.repositoryPickerTotalCount == candidates.count
        }

        let initialDerivationCount = viewModel.repositoryPickerDerivationCountForTesting
        let first = try #require(viewModel.displayedMentionCandidates.first)

        viewModel.isContextPickerFilterPresented = true
        viewModel.toggleRepoContext(first)
        viewModel.clearSelectedRepoContexts()

        #expect(viewModel.repositoryPickerDerivationCountForTesting == initialDerivationCount)
        #expect(viewModel.repositoryPickerDisplayedCount == AgentRepositoryPickerLogic.unselectedDisplayLimit)

        viewModel.selectedRepositorySources = [.weekly, .discovery]

        #expect(viewModel.repositoryPickerDerivationCountForTesting == initialDerivationCount + 1)
    }

    @Test("Repo Insight 替换单仓库选择时不关闭面板")
    func repoInsightReplacesSelectionWithoutClosingPicker() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.repoInsight])
        let first = mentionCandidate(id: 1, fullName: "octo/one")
        let second = mentionCandidate(id: 2, fullName: "octo/two")
        viewModel.mentionCandidates = [first, second]
        viewModel.presentContextPicker()

        viewModel.toggleRepoContext(first)
        viewModel.toggleRepoContext(second)

        #expect(viewModel.isContextPickerPresented)
        #expect(viewModel.selectedRepoContexts.map(\.id) == [2])
    }

    @Test("run 会把 runtime 事件投影成工作台状态")
    func runProjectsRuntimeEventsIntoWorkspaceState() async throws {
        let runID = UUID()
        let artifact = AgentArtifact(type: .markdown, title: "周刊", content: "# 周刊")
        let logArtifact = AgentArtifact(type: .log, title: "日志", content: "# Log")
        let user = AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("生成周刊")])
        let assistant = AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 1, parts: [.text("开始整理")])
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .messageAppended(user),
            .messageAppended(assistant),
            .artifactCreated(artifact),
            .artifactCreated(logArtifact),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "生成本周 GitHub 热门项目周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.runTitle == BuiltInAgents.githubWeeklyReport.title)
        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        #expect(viewModel.artifacts.count == 2)
        #expect(viewModel.selectedArtifact?.content == "# 周刊")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Agent 中间区可渲染为连续任务叙事而非调试卡片")
    func runSurfaceRendersEditorialActivityFeed() async throws {
        let runID = UUID()
        let calls = [
            AgentToolCall(id: "goal", name: "agent_parse_goal", input: .object([:]), sequence: 0),
            AgentToolCall(id: "repos", name: "context_resolve_repos", input: .object([:]), sequence: 1),
            AgentToolCall(id: "topics", name: "repo_cluster_topics", input: .object([:]), sequence: 2),
            AgentToolCall(id: "artifact", name: "artifact_build_weekly_report", input: .object([:]), sequence: 3)
        ]
        let user = AgentMessage(
            runID: runID,
            role: .user,
            turn: 0,
            sequence: 0,
            parts: [.text("provider prompt")]
        )
        let assistant = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 0,
            sequence: 1,
            parts: calls.map(AgentMessagePart.toolCall)
        )
        let narratives = [
            "已理解周报目标并确定本次任务范围。",
            "已读取 40 个候选仓库，准备筛选本周热点。",
            "已将仓库快照整理为 AI、开发工具与安全三个主题。",
            "已核对仓库引用并生成最终周报。"
        ]
        let results = zip(calls, narratives).map { pair in
            let (call, narrative) = pair
            return AgentMessagePart.toolResult(AgentToolResultMessage(
                toolCallID: call.id,
                toolName: call.name,
                output: .object([
                    "summary": .string(call.id == "repos" ? "40 个仓库" : "已完成"),
                    "log": .string(narrative)
                ]),
                isError: false,
                status: .completed,
                elapsedMilliseconds: 12,
                attempts: [],
                sources: [],
                sequence: call.sequence
            ))
        }
        let tool = AgentMessage(
            runID: runID,
            role: .tool,
            turn: 0,
            sequence: 2,
            parts: results
        )
        let artifact = AgentArtifact(
            type: .markdown,
            title: "GitHub 热门项目周报",
            content: """
            # GitHub 热门项目周报

            ## 本周风向

            AI Agent 基础设施与本地开发工具持续升温，安全工具也出现了新的高增长项目。

            ## 值得关注

            | 项目 | 方向 | 推荐理由 |
            | --- | --- | --- |
            | example/agent-kit | AI Agent | 任务编排清晰，适合快速验证工作流 |
            | example/dev-tool | 开发工具 | 本地优先，安装和迁移成本低 |
            """,
            sequence: 3
        )
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .messageAppended(user),
            .messageAppended(assistant),
            .messageAppended(tool),
            .artifactCreated(artifact),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "帮我生成本周 GitHub 热门开源项目周刊，风格参考阮一峰 Weekly。"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }
        // 运行态默认展开过程，正好覆盖用户最关注的 WorkBuddy 式过程流首屏。
        viewModel.status = .running

        let content = AgentMessageTimelineView(viewModel: viewModel)
            .frame(width: 820, height: 1_080)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 1_080),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        // LazyVStack 只有进入真实窗口和布局周期后才会实例化可见行；纯 ImageRenderer
        // 会得到尺寸正确但像素全白的假截图，无法承担 UI 回归门禁。
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 820)
        #expect(bitmap.pixelsHigh >= 1_080)
        let foregroundSamples = stride(from: 0, to: bitmap.pixelsWide, by: 20).reduce(into: 0) { count, x in
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 20) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.95 || color.greenComponent < 0.95 || color.blueComponent < 0.95 {
                    count += 1
                }
            }
        }
        #expect(foregroundSamples > 20)
    }

    @Test("selectedArtifactID 会联动 Inspector 当前产出物")
    func artifactSelectionUsesRealArtifactState() async throws {
        let first = AgentArtifact(type: .markdown, title: "周刊", content: "# Weekly")
        let second = AgentArtifact(type: .log, title: "日志", content: "run log")
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: "Run"),
            .artifactCreated(first),
            .artifactCreated(second),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "生成周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }
        viewModel.selectedArtifactID = second.id

        #expect(viewModel.selectedArtifact?.id == second.id)
        #expect(viewModel.selectedArtifact?.content == "run log")
    }

    @Test("knowledge audit 与 artifact 使用互斥 Inspector 选择")
    func knowledgeAuditSelectionDrivesInspectorState() async throws {
        let runID = UUID()
        let artifact = AgentArtifact(type: .markdown, title: "报告", content: "# Report")
        let audit = AgentKnowledgeRetrievalAudit(
            scopeMode: .prefer,
            frozenRepoIDs: [1, 2],
            explicitRepoIDs: [1],
            evidenceBlockCount: 1,
            citations: [],
            retrievalTrace: RAGRetrievalTrace(candidates: [
                RAGRetrievalCandidateTrace(repoID: 1, fullName: "octo/one"),
                RAGRetrievalCandidateTrace(repoID: 2, fullName: "octo/two")
            ]),
            diagnostics: nil,
            limitations: []
        )
        let toolMessage = AgentMessage(
            runID: runID,
            role: .tool,
            turn: 0,
            sequence: 2,
            parts: [.toolResult(AgentToolResultMessage(
                toolCallID: "call-knowledge",
                toolName: "knowledge_search",
                output: .object(["summary": .string("1 evidence")]),
                isError: false,
                status: .completed,
                toolAudit: .knowledge(audit),
                sequence: 2
            ))]
        )
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: "Run"),
            .messageAppended(toolMessage),
            .artifactCreated(artifact),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "检查仓库"
        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        viewModel.selectKnowledgeAudit(toolCallID: "call-knowledge")
        #expect(viewModel.selectedKnowledgeAudit?.scopeMode == .prefer)
        #expect(viewModel.selectedKnowledgeAudit?.metrics.candidateCount == 2)

        viewModel.selectArtifact(artifact.id)
        #expect(viewModel.selectedKnowledgeAudit == nil)
        #expect(viewModel.selectedArtifact?.id == artifact.id)
    }

    @Test("通用 Inspector 按 Agent 类型生成正确导出文件名")
    func artifactExportFilenameUsesSelectedAgent() {
        let viewModel = AgentWorkspaceViewModel(agents: [
            BuiltInAgents.githubWeeklyReport,
            BuiltInAgents.repoInsight
        ])
        let markdown = AgentArtifact(type: .markdown, title: "Report", content: "# Report")
        let log = AgentArtifact(type: .log, title: "Log", content: "run log")

        #expect(viewModel.suggestedFilename(for: markdown) == "starcat-weekly-report.md")
        viewModel.selectedAgentID = BuiltInAgents.repoInsight.id
        #expect(viewModel.suggestedFilename(for: markdown) == "starcat-repo-insight.md")
        #expect(viewModel.suggestedFilename(for: log) == "starcat-agent-run.txt")
        viewModel.selectedAgentID = "future-agent"
        #expect(viewModel.suggestedFilename(for: markdown) == "starcat-agent-artifact.md")
    }

    @Test("cancel 会立即进入取消状态")
    func cancelMarksWorkspaceAsCancelled() {
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )
        configureRunnable(viewModel)
        viewModel.prompt = "生成本周 GitHub 热门项目周刊"

        viewModel.run()
        viewModel.cancel()

        #expect(viewModel.status == .cancelled)
        #expect(viewModel.isRunning == false)
    }

    @Test("approvalUpdated 会保存待审批事实")
    func approvalUpdatedStoresPendingApproval() async throws {
        let approval = AgentApprovalRequest(
            runID: UUID(),
            toolCallID: "call-tag",
            toolName: "tag_propose",
            input: .object(["tag": .string("database")]),
            permission: .requiresConfirmation,
            sequence: 1
        )
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .approvalUpdated(approval),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "规划标签"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.approvals == [approval])
    }

    @Test("reasoning 与正文增量会分别投影到流式缓冲")
    func projectsReasoningAndTextDeltasSeparately() async throws {
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .assistantReasoningDelta("先检查本地上下文"),
            .assistantDelta("正在生成周刊"),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "生成周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.assistantReasoningOutput == "先检查本地上下文")
        #expect(viewModel.assistantOutput == "正在生成周刊")
    }

    @Test("密集 token 只形成少量流式展示快照")
    func throttlesBurstStreamingPresentationUpdates() async throws {
        let deltaCount = 400
        let runtime = EventReplayAgentRuntime(events:
            [.runStarted(title: BuiltInAgents.githubWeeklyReport.title)]
                + Array(repeating: AgentRunEvent.assistantDelta("字"), count: deltaCount)
                + [.runCompleted]
        )
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "生成周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.assistantOutput == String(repeating: "字", count: deltaCount))
        // 首包立即展示、字符阈值提交、结束 flush；即使慢速测试机跨过时间阈值，
        // 刷新次数也必须远低于 token 数，防止再次按 token 驱动 SwiftUI 布局。
        #expect(viewModel.streamingPresentationUpdateCountForTesting < 20)
    }

    @Test("assistant 消息落库后会清空临时流式缓冲")
    func persistedAssistantMessageClearsStreamingBuffers() async throws {
        let message = AgentMessage(
            runID: UUID(),
            role: .assistant,
            turn: 0,
            sequence: 1,
            parts: [.reasoning("已完成分析"), .text("最终正文")]
        )
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: "Run"),
            .assistantReasoningDelta("分析中"),
            .assistantDelta("生成中"),
            .messageAppended(message),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "生成周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.assistantReasoningOutput.isEmpty)
        #expect(viewModel.assistantOutput.isEmpty)
        #expect(viewModel.messages == [message])
    }

    @Test("批准操作会向 Runtime 发送精确关联命令")
    func approveSendsCorrelatedRuntimeCommand() async throws {
        let approval = AgentApprovalRequest(
            runID: UUID(),
            toolCallID: "call-write",
            toolName: "write_tag",
            input: .object(["tag": .string("swift")]),
            permission: .requiresConfirmation,
            sequence: 1
        )
        let recorder = AgentCommandRecorder()
        let runtime = CommandRecordingAgentRuntime(
            events: [.runStarted(title: "Run"), .approvalUpdated(approval)],
            recorder: recorder
        )
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        configureRunnable(viewModel)
        viewModel.prompt = "写入标签"

        viewModel.run()
        try await waitUntil { viewModel.status == .waitingForConfirmation }
        viewModel.approve(approval)
        try await waitUntil { await recorder.commandCount() == 1 }
        let commands = await recorder.commands()
        let command = try #require(commands.first)

        guard case .decideApproval(let runID, let approvalID, let toolCallID, let decision) = command else {
            Issue.record("Expected decideApproval command")
            return
        }
        #expect(runID == approval.runID)
        #expect(approvalID == approval.id)
        #expect(toolCallID == approval.toolCallID)
        #expect(decision == .approved)
    }

    @Test("run 会先冻结 context 再交给 runtime")
    func runPassesContextProviderSnapshotIntoRuntime() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot: 1 repo",
            repos: [
                AgentRepoSnapshot(
                    id: 1,
                    owner: "groue",
                    name: "GRDB.swift",
                    fullName: "groue/GRDB.swift",
                    description: "SQLite toolkit",
                    language: "Swift",
                    starsCount: 7800,
                    topics: ["sqlite"],
                    isPrivate: false,
                    isStarred: true,
                    starredAt: "2026-07-07T00:00:00Z",
                    htmlUrl: "https://github.com/groue/GRDB.swift"
                )
            ]
        )
        let runtime = ContextEchoAgentRuntime()
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime,
            contextProvider: StaticAgentRunContextProvider(context: context)
        )
        configureRunnable(viewModel)
        viewModel.prompt = "生成本周 GitHub 热门项目周刊"
        viewModel.attachments = [AgentPromptAttachment(name: "brief.md", content: "重点关注本地 AI 工具")]

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.selectedArtifact?.content.contains("Unit Snapshot: 1 repo") == true)
        #expect(viewModel.selectedArtifact?.content.contains("groue/GRDB.swift") == true)
        #expect(viewModel.selectedArtifact?.content.contains("brief.md: 重点关注本地 AI 工具") == true)
        #expect(viewModel.attachments.isEmpty)
    }

    @Test("发送后清空输入框与当前 Agent 草稿，但 Runtime 仍收到冻结指令")
    func submissionClearsComposerAndSubmittedDraft() async throws {
        let recorder = AgentRunInputRecorder()
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: "Run"),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport, BuiltInAgents.repoInsight],
            runtime: runtime,
            contextProvider: RecordingAgentRunContextProvider(recorder: recorder)
        )
        configureRunnable(viewModel)
        viewModel.prompt = "给我最近 7 天的热门仓库"
        viewModel.handlePromptChanged()

        viewModel.run()

        #expect(viewModel.prompt.isEmpty)
        try await waitUntil { viewModel.status == .completed }
        #expect(await recorder.input()?.goal == "给我最近 7 天的热门仓库")
        #expect(viewModel.currentRunUserPrompt == "给我最近 7 天的热门仓库")

        // 切换 Agent 后再回来也不能恢复已经发送过的旧草稿。
        viewModel.selectAgent(BuiltInAgents.repoInsight)
        viewModel.selectAgent(BuiltInAgents.githubWeeklyReport)
        #expect(viewModel.prompt.isEmpty)
    }

    @Test("Weekly 空 prompt 会使用固定默认指令直接运行")
    func emptyPromptUsesWeeklyDefaultPrompt() {
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )
        configureRunnable(viewModel)

        viewModel.run()

        #expect(viewModel.status == .planning)
        #expect(viewModel.prompt.isEmpty)
        #expect(viewModel.isRunning)
    }

    @Test("每个 Agent 独立恢复自己的输入草稿")
    func restoresDraftPerAgent() {
        let viewModel = AgentWorkspaceViewModel(agents: [
            BuiltInAgents.githubWeeklyReport,
            BuiltInAgents.repoInsight
        ])
        viewModel.prompt = "weekly draft"
        viewModel.handlePromptChanged()

        viewModel.selectAgent(BuiltInAgents.repoInsight)
        viewModel.prompt = "insight draft"
        viewModel.handlePromptChanged()
        viewModel.selectAgent(BuiltInAgents.githubWeeklyReport)

        #expect(viewModel.prompt == "weekly draft")
        viewModel.selectAgent(BuiltInAgents.repoInsight)
        #expect(viewModel.prompt == "insight draft")
    }

    @Test("发送瞬间冻结结构化 Run Input")
    func freezesStructuredRunInputBeforeAsyncContextBuild() async throws {
        let recorder = AgentRunInputRecorder()
        let provider = RecordingAgentRunContextProvider(recorder: recorder)
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: "Run"),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime,
            contextProvider: provider
        )
        let repo = AIComposerRepoReference(
            id: 42,
            owner: "groue",
            name: "GRDB.swift",
            fullName: "groue/GRDB.swift",
            language: "Swift",
            starsCount: 8_000
        )
        viewModel.prompt = "参考 https://github.com/groue/GRDB.swift 生成周刊"
        viewModel.handlePromptChanged()
        let model = AIModelDescriptor(providerID: "provider", name: "agent-model")
        viewModel.configureModelOptions(
            [model],
            defaultProviderID: model.providerID,
            defaultModelName: model.name
        )
        viewModel.selectedRepoContexts = [repo]
        viewModel.attachments = [AgentPromptAttachment(name: "brief.md", content: "private")]
        viewModel.webSearchEnabled = true

        viewModel.run()
        viewModel.prompt = "mutated"
        viewModel.selectedRepoContexts = []
        viewModel.webSearchEnabled = false
        try await waitUntil { viewModel.status == .completed }
        let input = try #require(await recorder.input())

        #expect(input.goal.contains("生成周刊"))
        #expect(input.explicitRepos == [repo])
        #expect(input.selectedModelID == model.id)
        #expect(input.attachments.first?.content == "private")
        #expect(input.githubLinks.first?.owner == "groue")
        #expect(input.webSearchEnabled)
    }

    @Test("共享 Composer 键盘策略与 RAG 设置语义一致")
    func composerKeyboardPolicyMatchesSettings() {
        #expect(AIComposerKeyboardPolicy.action(for: [], requiresCommandReturn: false) == .send)
        #expect(AIComposerKeyboardPolicy.action(for: [.command], requiresCommandReturn: false) == .insertNewline)
        #expect(AIComposerKeyboardPolicy.action(for: [], requiresCommandReturn: true) == .insertNewline)
        #expect(AIComposerKeyboardPolicy.action(for: [.command], requiresCommandReturn: true) == .send)
    }

    @Test("reloadHistory 会加载真实 run 历史")
    func reloadHistoryLoadsPersistedRuns() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        _ = try await repository.createRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "历史 run",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )
        viewModel.configureRunRepository(repository)

        await viewModel.reloadHistory()

        #expect(viewModel.historyRuns.count == 1)
        #expect(viewModel.historyRuns.first?.userPrompt == "历史 run")
    }

    @Test("首次历史初始化把上次进程遗留 Run 转为可重试失败态")
    func initializeHistoryRecoversInterruptedRunForRetry() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID()
        let staleRun = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "恢复中断运行",
            context: .empty,
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("恢复中断运行")]),
            runStatus: .running
        )
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )
        viewModel.configureRunRepository(repository)

        await viewModel.initializeHistory()
        await viewModel.openHistoryRun(staleRun)

        #expect(viewModel.historyRuns.first?.status == AgentRunStatus.failed.rawValue)
        #expect(viewModel.status == .failed)
        #expect(viewModel.errorMessage == String.l10n("agent.persistence.error.runInterrupted"))
        #expect(viewModel.canRetryFailedRun)
    }

    @Test("openHistoryRun 会只读恢复 run 快照")
    func openHistoryRunRestoresSnapshot() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000001010")!
        let run = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "打开历史",
            context: AgentRunContext(
                sourceDescription: "Unit",
                explicitRepos: [AIComposerRepoReference(
                    id: 42,
                    owner: "groue",
                    name: "GRDB.swift",
                    fullName: "groue/GRDB.swift",
                    language: "Swift",
                    starsCount: 8_000
                )],
                explicitRepoMode: .exclude,
                githubLinks: [AIComposerGitHubLink(
                    url: URL(string: "https://github.com/groue/GRDB.swift")!,
                    owner: "groue",
                    repository: "GRDB.swift"
                )],
                webSearchEnabled: true
            ),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let call = AgentToolCall(
            id: "history-call",
            name: "history_tool",
            input: .object(["input": .string("input")]),
            sequence: 1
        )
        let assistant = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 0,
            sequence: 1,
            parts: [.toolCall(call)]
        )
        let result = AgentToolResultMessage(
            toolCallID: call.id,
            toolName: call.name,
            output: .object(["value": .string("output")]),
            isError: false,
            status: .completed,
            sequence: 2
        )
        let toolMessage = AgentMessage(
            runID: runID,
            role: .tool,
            turn: 0,
            sequence: 2,
            parts: [.toolResult(result)]
        )
        let final = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 1,
            sequence: 3,
            parts: [.text("# 历史")]
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("打开历史")]),
            runStatus: .running
        )
        try await repository.appendMessage(assistant, runStatus: .running)
        try await repository.appendMessage(toolMessage, runStatus: .running)
        try await repository.appendMessage(final, runStatus: .running)
        let artifact = AgentArtifact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001013")!,
            type: .markdown,
            title: "历史产物",
            content: "# 历史",
            toolCallID: call.id,
            messageID: toolMessage.id,
            sequence: toolMessage.sequence,
            createdAt: Date(timeIntervalSince1970: 1_788_000_120)
        )
        try await repository.appendArtifact(artifact, runID: runID)
        try await repository.updateRunStatus(
            runID: runID,
            status: .completed,
            model: "test-model",
            usage: .zero,
            errorMessage: nil,
            finishedAt: Date()
        )
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )
        viewModel.configureRunRepository(repository)
        viewModel.prompt = "尚未发送的草稿"
        viewModel.handlePromptChanged()

        await viewModel.openHistoryRun(run)

        #expect(viewModel.selectedHistoryRunID == run.id)
        #expect(viewModel.prompt == "尚未发送的草稿")
        #expect(viewModel.currentRunUserPrompt == "打开历史")
        #expect(viewModel.status == .completed)
        #expect(viewModel.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(viewModel.selectedArtifact?.content == "# 历史")
        #expect(viewModel.assistantOutput.isEmpty)
        #expect(viewModel.selectedRepoContexts.map(\.id) == [42])
        #expect(viewModel.explicitRepoMode == .exclude)
        #expect(viewModel.githubLinks.first?.repository == "GRDB.swift")
        #expect(viewModel.webSearchEnabled)
    }

    @Test("重启后打开 pending approval 只恢复等待态且不会自动决策")
    func openPendingApprovalRestoresWaitingStateWithoutAutoDecision() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000001020")!
        let run = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "等待审批",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let call = AgentToolCall(
            id: "pending-call",
            name: "write_tag",
            input: .object(["tag": .string("swift")]),
            sequence: 1
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("等待审批")]),
            runStatus: .running
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 1, parts: [.toolCall(call)]),
            runStatus: .running
        )
        let approval = AgentApprovalRequest(
            runID: runID,
            toolCallID: call.id,
            toolName: call.name,
            input: call.input,
            permission: .requiresConfirmation,
            sequence: call.sequence
        )
        try await repository.saveApproval(approval, runStatus: .waitingForConfirmation)
        let recorder = RestartApprovalRecorder()
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: RestartApprovalRuntime(approval: approval, recorder: recorder)
        )
        viewModel.configureRunRepository(repository)

        await viewModel.openHistoryRun(run)
        try await waitUntil {
            let resumeCount = await recorder.resumeCount()
            return viewModel.status == .waitingForConfirmation && resumeCount == 1
        }

        #expect(viewModel.approvals == [approval])
        #expect(await recorder.commands().isEmpty)
        #expect(viewModel.messages.map(\.sequence) == [0, 1])
    }

    @Test("重启后附件正文不可恢复时禁止继续 pending approval")
    func pendingApprovalWithTransientAttachmentFailsClosedAfterRestart() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID()
        let run = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "根据附件执行",
            context: AgentRunContext(
                sourceDescription: "Unit",
                attachments: [AgentPromptAttachment(name: "private.md", content: "transient body")]
            ),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let approval = AgentApprovalRequest(
            runID: runID,
            toolCallID: "pending-attachment-call",
            toolName: "write_tag",
            input: .object(["tag": .string("swift")]),
            permission: .requiresConfirmation,
            sequence: 1
        )
        try await repository.saveApproval(approval, runStatus: .waitingForConfirmation)
        let recorder = RestartApprovalRecorder()
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: RestartApprovalRuntime(approval: approval, recorder: recorder)
        )
        viewModel.configureRunRepository(repository)

        await viewModel.openHistoryRun(run)

        #expect(viewModel.status == .waitingForConfirmation)
        #expect(viewModel.errorMessage == String.l10n("agent.loop.error.contextUnavailable"))
        #expect(await recorder.resumeCount() == 0)
        #expect(await recorder.commands().isEmpty)
    }

    @Test("失败历史 run 只触发一次重试并立即关闭重复入口")
    func failedHistoryRunRetriesOnce() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID()
        let run = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "重试失败运行",
            context: .empty,
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("重试失败运行")]),
            runStatus: .running
        )
        try await repository.updateRunStatus(
            runID: runID,
            status: .failed,
            model: "test-model",
            usage: .zero,
            errorMessage: "provider unavailable",
            finishedAt: Date(timeIntervalSince1970: 1_788_000_010)
        )
        let recorder = FailedRunRetryRecorder()
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: FailedRunRetryRuntime(recorder: recorder)
        )
        viewModel.configureRunRepository(repository)

        await viewModel.openHistoryRun(run)
        #expect(viewModel.canRetryFailedRun)

        viewModel.retryFailedRun()
        viewModel.retryFailedRun()
        try await waitUntil {
            await recorder.retryCount() == 1 && viewModel.status == .completed
        }

        #expect(await recorder.retryCount() == 1)
        #expect(!viewModel.canRetryFailedRun)
        #expect(viewModel.errorMessage == nil)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !(await predicate()) {
            if start.duration(to: ContinuousClock.now) > .nanoseconds(Int64(timeoutNanoseconds)) {
                Issue.record("Timed out waiting for AgentWorkspaceViewModel state")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func configureRunnable(_ viewModel: AgentWorkspaceViewModel) {
        let model = AIModelDescriptor(providerID: "test-provider", name: "test-agent-model")
        viewModel.configureModelOptions(
            [model],
            defaultProviderID: model.providerID,
            defaultModelName: model.name
        )
    }

    private func mentionCandidate(id: Int64, fullName: String) -> RAGMentionCandidate {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        var repo = Repo.makeMinimal(owner: parts[0], name: parts[1])
        repo.id = id
        return RAGMentionCandidate(repo: repo)
    }

    private func agentRepositoryCandidate(id: Int64) -> AgentRepositoryCandidate {
        let fullName = "owner-\(id % 50)/repo-\(id)"
        let source: AgentRepositorySource = switch id % 4 {
        case 0: .local
        case 1: .weekly
        case 2: .trending
        default: .discovery
        }
        return AgentRepositoryCandidate(
            snapshot: AgentRepoSnapshot(
                id: id,
                owner: "owner-\(id % 50)",
                name: "repo-\(id)",
                fullName: fullName,
                description: "Repository \(id)",
                language: id.isMultiple(of: 2) ? "Swift" : "TypeScript",
                starsCount: Int(id),
                topics: [],
                isPrivate: false,
                isStarred: id.isMultiple(of: 3),
                starredAt: nil,
                htmlUrl: "https://github.com/\(fullName)",
                sourceIDs: [source.rawValue],
                firstObservedAt: nil,
                latestObservedAt: "2026-08-04T12:00:00Z"
            ),
            ownerAvatar: nil,
            sources: [source],
            status: .unread,
            isArchived: false,
            isFork: false,
            pushedAt: "2026-08-04T12:00:00Z",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-08-04T12:00:00Z",
            libraryUpdatedAt: nil,
            firstObservedAt: nil,
            latestObservedAt: "2026-08-04T12:00:00Z",
            normalizedSearchText: RAGMentionCandidate.normalize(fullName)
        )
    }
}

private struct FixedWorkspaceAgentRepositoryCatalog: AgentRepositoryCatalogProviding {
    let candidatesValue: [AgentRepositoryCandidate]

    init(candidates: [AgentRepositoryCandidate]) {
        candidatesValue = candidates
    }

    func candidates() async throws -> [AgentRepositoryCandidate] {
        candidatesValue
    }
}

private struct EventReplayAgentRuntime: AgentRuntime {
    let events: [AgentRunEvent]

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private struct NeverFinishingAgentRuntime: AgentRuntime {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            continuation.yield(.runStarted(title: definition.title))
        }
    }
}

private struct CommandRecordingAgentRuntime: AgentRuntime {
    let events: [AgentRunEvent]
    let recorder: AgentCommandRecorder

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func send(_ command: AgentRunCommand) async {
        await recorder.record(command)
    }
}

private struct RestartApprovalRuntime: AgentRuntime {
    let approval: AgentApprovalRequest
    let recorder: RestartApprovalRecorder

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { $0.finish() }
    }

    func resumePendingRun(
        snapshot: AgentRunSnapshotRecord,
        definition: AgentDefinition
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            Task {
                await recorder.recordResume()
                continuation.yield(.approvalUpdated(approval))
                continuation.finish()
            }
        }
    }

    func send(_ command: AgentRunCommand) async {
        await recorder.record(command)
    }
}

private struct FailedRunRetryRuntime: AgentRuntime {
    let recorder: FailedRunRetryRecorder

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { $0.finish() }
    }

    func retryFailedRun(
        snapshot: AgentRunSnapshotRecord,
        definition: AgentDefinition
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            Task {
                await recorder.recordRetry(runID: snapshot.run.id)
                continuation.yield(.runStarted(title: definition.title))
                continuation.yield(.runCompleted)
                continuation.finish()
            }
        }
    }
}

private actor FailedRunRetryRecorder {
    private var runIDs: [String] = []

    func recordRetry(runID: String) { runIDs.append(runID) }
    func retryCount() -> Int { runIDs.count }
}

private actor RestartApprovalRecorder {
    private var resumes = 0
    private var recordedCommands: [AgentRunCommand] = []

    func recordResume() { resumes += 1 }
    func record(_ command: AgentRunCommand) { recordedCommands.append(command) }
    func resumeCount() -> Int { resumes }
    func commands() -> [AgentRunCommand] { recordedCommands }
}

private actor AgentCommandRecorder {
    private var recordedCommands: [AgentRunCommand] = []

    func record(_ command: AgentRunCommand) {
        recordedCommands.append(command)
    }

    func commandCount() -> Int { recordedCommands.count }
    func commands() -> [AgentRunCommand] { recordedCommands }
}

private struct StaticAgentRunContextProvider: AgentRunContextProviding {
    let context: AgentRunContext

    func makeContext(
        definition: AgentDefinition,
        input: AgentRunInput
    ) async -> AgentRunContext {
        var snapshot = context
        snapshot.attachments = input.attachments
        snapshot.explicitRepos = input.explicitRepos
        snapshot.githubLinks = input.githubLinks
        snapshot.webSearchEnabled = input.webSearchEnabled
        return snapshot
    }
}

private actor AgentRunInputRecorder {
    private var recordedInput: AgentRunInput?

    func record(_ input: AgentRunInput) {
        recordedInput = input
    }

    func input() -> AgentRunInput? { recordedInput }
}

private struct RecordingAgentRunContextProvider: AgentRunContextProviding {
    let recorder: AgentRunInputRecorder

    func makeContext(
        definition: AgentDefinition,
        input: AgentRunInput
    ) async -> AgentRunContext {
        await recorder.record(input)
        return AgentRunContext(
            sourceDescription: input.source,
            attachments: input.attachments,
            explicitRepos: input.explicitRepos,
            explicitRepoMode: input.explicitRepoMode,
            selectedModelID: input.selectedModelID,
            githubLinks: input.githubLinks,
            webSearchEnabled: input.webSearchEnabled
        )
    }
}

private struct ContextEchoAgentRuntime: AgentRuntime {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let repoNames = context.repos.map(\.fullName).joined(separator: ", ")
            let attachmentText = context.attachments.map { "\($0.name): \($0.content)" }.joined(separator: "\n")
            continuation.yield(.runStarted(title: definition.title))
            continuation.yield(.artifactCreated(AgentArtifact(
                type: .markdown,
                title: "Context Echo",
                content: "\(context.sourceDescription)\n\(repoNames)\n\(attachmentText)"
            )))
            continuation.yield(.runCompleted)
            continuation.finish()
        }
    }
}
