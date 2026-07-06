//
//  AgentRuntime.swift
//  Starcat
//
//  Agent 运行时协议与默认实现。
//
//  DefaultAgentRuntime 先执行 Starcat 本地 read-only tools,把真实上下文、工具输入输出和
//  Artifact 串成可审计事件流。后续接入 OpenAI tool-calling 时，应保留同一套事件语义。
//

import Foundation

/// Agent runtime 统一协议。
protocol AgentRuntime: Sendable {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent>
}

/// 默认 Agent 运行时。
struct DefaultAgentRuntime: AgentRuntime {

    private let stepStartDelayNanoseconds: UInt64
    private let stepCompletionDelayNanoseconds: UInt64
    private let textGenerator: any AgentTextGenerating

    /// 创建 P0 默认运行时。
    ///
    /// 延迟值默认服务于 UI 演示：步骤不要瞬间闪过，用户能看清 Agent 正在推进。
    /// 测试可以把延迟注入为 0，避免单测依赖固定等待时间。
    init(
        stepStartDelayNanoseconds: UInt64 = 280_000_000,
        stepCompletionDelayNanoseconds: UInt64 = 420_000_000,
        textGenerator: any AgentTextGenerating = DisabledAgentTextGenerator()
    ) {
        self.stepStartDelayNanoseconds = stepStartDelayNanoseconds
        self.stepCompletionDelayNanoseconds = stepCompletionDelayNanoseconds
        self.textGenerator = textGenerator
    }

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let task = Task {
                var runLog: [String] = []
                let plan = Self.makeWeeklyReportPlan(context: context)
                let steps = Self.makeWeeklyReportSteps()

                continuation.yield(.runStarted(title: definition.title))
                runLog.append("Run started: \(definition.title)")

                continuation.yield(.planCreated(plan))
                runLog.append("Plan created: \(plan.count) steps")

                for (index, step) in steps.enumerated() {
                    try? await Task.sleep(nanoseconds: stepStartDelayNanoseconds)
                    guard !Task.isCancelled else {
                        continuation.yield(.runCancelled)
                        continuation.finish()
                        return
                    }

                    var running = step
                    running.status = .running
                    continuation.yield(.stepStarted(id: running.id))
                    continuation.yield(.stepUpdated(running))
                    runLog.append("Step started: \(running.title)")

                    let toolResult = Self.executeTool(
                        index: index,
                        prompt: prompt,
                        context: context
                    )

                    try? await Task.sleep(nanoseconds: stepCompletionDelayNanoseconds)
                    guard !Task.isCancelled else {
                        continuation.yield(.runCancelled)
                        continuation.finish()
                        return
                    }

                    var completed = step
                    completed.status = .completed
                    completed.detail = toolResult.output.summary
                    continuation.yield(.stepUpdated(completed))
                    runLog.append("Step completed: \(completed.title)")

                    continuation.yield(.toolOutput(toolResult.output))
                    continuation.yield(.trace(toolResult.trace))
                    runLog.append("Tool output: \(toolResult.output.toolName) - \(toolResult.output.summary)")
                }

                let topics = GitHubWeeklyReportTools.clusterTopics(context: context).0
                let (draftMarkdown, artifactTool) = GitHubWeeklyReportTools.buildMarkdown(
                    prompt: prompt,
                    context: context,
                    topics: topics
                )
                let markdown: String
                do {
                    let generated = try await textGenerator.generateWeeklyReport(
                        prompt: prompt,
                        context: context,
                        draftMarkdown: draftMarkdown
                    )
                    markdown = generated
                    continuation.yield(.assistantDelta(generated))
                    continuation.yield(.trace(AgentTraceSpan(
                        kind: "LLM",
                        title: "AI 生成周刊正文",
                        summary: "\(generated.count) chars",
                        input: String(draftMarkdown.prefix(1_200)),
                        output: String(generated.prefix(1_200)),
                        log: "model_output=markdown"
                    )))
                    runLog.append("LLM generation completed: \(generated.count) chars")
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    continuation.yield(.trace(AgentTraceSpan(
                        kind: "LLM",
                        title: "AI 生成周刊正文",
                        summary: "failed",
                        input: String(draftMarkdown.prefix(1_200)),
                        output: message,
                        log: "model_output=failed",
                        status: .failed
                    )))
                    continuation.yield(.runFailed(message))
                    continuation.finish()
                    return
                }
                let markdownArtifact = AgentArtifact(
                    type: .markdown,
                    title: "本周 GitHub 热门项目周刊",
                    content: markdown
                )
                continuation.yield(.toolOutput(artifactTool.output))
                continuation.yield(.trace(AgentTraceSpan(
                    kind: "Artifact",
                    title: markdownArtifact.title,
                    summary: markdownArtifact.type.title,
                    input: artifactTool.output.input,
                    output: artifactTool.output.output,
                    log: artifactTool.output.log,
                    relatedToolOutputID: artifactTool.output.id,
                    relatedArtifactID: markdownArtifact.id
                )))
                continuation.yield(.artifactCreated(markdownArtifact))
                continuation.yield(.artifactCreated(AgentArtifact(
                    type: .log,
                    title: "Agent Run Log",
                    content: Self.makeRunLog(runLog, context: context)
                )))
                continuation.yield(.runCompleted)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func makeWeeklyReportPlan(context: AgentRunContext) -> [AgentPlanStep] {
        [
            AgentPlanStep(
                title: "确认输出目标",
                detail: "把用户输入收敛为 GitHub Weekly Report,输出 Markdown artifact。"
            ),
            AgentPlanStep(
                title: "读取候选来源",
                detail: "读取 Starcat 冻结仓库快照: \(context.repos.count) repos。"
            ),
            AgentPlanStep(
                title: "生成可复查产物",
                detail: "输出报告正文、工具 trace 和 run log,保持 read-only。"
            )
        ]
    }

    private static func makeWeeklyReportSteps() -> [AgentRunStep] {
        [
            AgentRunStep(
                title: "解析任务目标",
                detail: "识别用户希望生成 Weekly Report，并确认输出为 Markdown artifact。"
            ),
            AgentRunStep(
                title: "准备数据源",
                detail: "读取冻结的 Starcat 仓库快照。"
            ),
            AgentRunStep(
                title: "聚类主题",
                detail: "把候选仓库按语言和主题收敛为周刊段落。"
            ),
            AgentRunStep(
                title: "生成周刊母稿",
                detail: "按技术周刊结构生成导语、主题段落、项目解读与结尾。"
            )
        ]
    }

    private static func executeTool(
        index: Int,
        prompt: String,
        context: AgentRunContext
    ) -> WeeklyReportToolResult {
        switch index {
        case 0:
            return GitHubWeeklyReportTools.parseGoal(prompt: prompt, context: context)
        case 1:
            return GitHubWeeklyReportTools.resolveCandidateRepos(context: context)
        default:
            return GitHubWeeklyReportTools.clusterTopics(context: context).1
        }
    }

    private static func makeRunLog(_ lines: [String], context: AgentRunContext) -> String {
        """
        # Agent Run Log

        > Runtime: DefaultAgentRuntime read-only tools
        > Context: \(context.sourceDescription)
        > Constraint: no write operations

        \(lines.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}
