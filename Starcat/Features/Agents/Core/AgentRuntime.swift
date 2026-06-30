//
//  AgentRuntime.swift
//  Starcat
//
//  Agent 运行时协议与 P0 默认实现。
//
//  P0 的 DefaultAgentRuntime 是 deterministic runtime：它不调用外部 LLM，也不做真实
//  tool-calling。这样第一版可以先验证 Agent Workspace、步骤时间线、Artifact、取消
//  和导出交互都能跑通；后续接入 OpenAI tools / AgentRunKit 时，只替换 Runtime 实现。
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

/// P0 默认运行时。
struct DefaultAgentRuntime: AgentRuntime {

    private let stepStartDelayNanoseconds: UInt64
    private let stepCompletionDelayNanoseconds: UInt64

    /// 创建 P0 默认运行时。
    ///
    /// 延迟值默认服务于 UI 演示：步骤不要瞬间闪过，用户能看清 Agent 正在推进。
    /// 测试可以把延迟注入为 0，避免单测依赖固定等待时间。
    init(
        stepStartDelayNanoseconds: UInt64 = 280_000_000,
        stepCompletionDelayNanoseconds: UInt64 = 420_000_000
    ) {
        self.stepStartDelayNanoseconds = stepStartDelayNanoseconds
        self.stepCompletionDelayNanoseconds = stepCompletionDelayNanoseconds
    }

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let task = Task {
                let steps = Self.makeWeeklyReportSteps()
                continuation.yield(.runStarted(title: definition.title))

                for step in steps {
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

                    try? await Task.sleep(nanoseconds: stepCompletionDelayNanoseconds)
                    guard !Task.isCancelled else {
                        continuation.yield(.runCancelled)
                        continuation.finish()
                        return
                    }

                    var completed = step
                    completed.status = .completed
                    continuation.yield(.stepUpdated(completed))
                }

                let markdown = Self.makeWeeklyMarkdown(prompt: prompt, context: context)
                continuation.yield(.artifactCreated(AgentArtifact(
                    type: .markdown,
                    title: "本周 GitHub 热门项目周刊",
                    content: markdown
                )))
                continuation.yield(.runCompleted)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func makeWeeklyReportSteps() -> [AgentRunStep] {
        [
            AgentRunStep(
                title: "解析任务目标",
                detail: "识别用户希望生成 Weekly Report，并确认输出为 Markdown artifact。"
            ),
            AgentRunStep(
                title: "准备数据源",
                detail: "P0 使用本地演示数据验证 Agent 底座；后续替换为 trending.fetchRepos / weekly.fetchFeed tools。"
            ),
            AgentRunStep(
                title: "聚类主题",
                detail: "将候选 repo 收敛为 Agent 工具链、本地优先应用、开发者效率三个主题。"
            ),
            AgentRunStep(
                title: "生成周刊母稿",
                detail: "按技术周刊结构生成导语、主题段落、项目解读与结尾。"
            ),
            AgentRunStep(
                title: "创建 Markdown Artifact",
                detail: "把母稿保存为可预览、复制和导出的 Markdown 产出物。"
            )
        ]
    }

    private static func makeWeeklyMarkdown(prompt: String, context: AgentRunContext) -> String {
        """
        # 本周 GitHub 热门项目观察

        > 生成来源：\(context.sourceDescription)
        > 用户目标：\(prompt.isEmpty ? "生成本周热门开源项目周刊" : prompt)

        ## 本周趋势

        这一期先验证 Starcat Agent 底座的完整运行链路：用户输入目标，Agent 展示执行步骤，最终生成可复制、可导出的 Markdown Artifact。后续接入真实 tool-calling 后，这里会替换为基于 `trending-api`、Weekly feed 和用户手选 repo 的实时内容。

        ## 主题一：AI Agent 工具链

        Agent 工具链仍然是本周最值得关注的方向。它们的共同点不是“又一个聊天框”，而是把工具调用、步骤追踪、产出物管理和人工确认组合成可验证工作流。

        - 是什么：围绕 Agent runtime、tool calling、workflow、artifact 的工程化能力。
        - 为什么值得关注：开发者工具正在从单次问答转向多步骤任务执行。
        - Starcat 相关性：对应当前正在实现的 Agent Workspace 和 AgentRuntime 底座。

        ## 主题二：本地优先应用

        本地优先仍然是开发者工具的重要差异化方向。对 Starcat 来说，Agent 运行记录、步骤日志和产出物应优先保存在本机，只有用户明确选择时才调用外部服务或导出文件。

        ## 主题三：开发者效率

        真正有价值的 Agent 不应停留在“自动生成文本”，而要能把 GitHub 数据、README、Release、用户收藏和本地笔记组织成可复查的报告。

        ## 下一步

        P0 底座跑通后，下一步应把当前 deterministic runtime 替换为 tool-calling runtime，并接入：

        1. `trending.fetchRepos`
        2. `weekly.fetchFeed`
        3. `repo.getOverview`
        4. `report.generate`

        ## 总结

        这份报告是 Agent 底座的可运行验证样例。它证明 Workspace、步骤时间线、Artifact 预览、复制和导出交互可以独立于具体 LLM SDK 先落地。
        """
    }
}
