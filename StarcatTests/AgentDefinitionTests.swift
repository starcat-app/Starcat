//
//  AgentDefinitionTests.swift
//  StarcatTests
//
//  内置 Agent 定义契约测试。
//
//  Runtime 会按 `toolIDs` 顺序执行工具,所以首个 Weekly Agent 的工具列表必须稳定。
//  这里锁住定义层,避免后续改 UI 文案时误删工具声明。
//

import Testing
@testable import Starcat

@Suite("AgentDefinition")
struct AgentDefinitionTests {

    @Test("Weekly Agent 声明线性工具序列和产物类型")
    func weeklyAgentDeclaresToolSequence() {
        let agent = BuiltInAgents.githubWeeklyReport

        #expect(agent.toolIDs == [
            "agent_parse_goal",
            "context_resolve_repos",
            "external_search",
            "repo_cluster_topics",
            "artifact_build_weekly_report"
        ])
        #expect(agent.artifactTypes == [.markdown, .log])
    }

    @Test("Repo Insight Agent 声明只读工具序列并默认启用")
    func repoInsightDeclaresToolSequence() {
        let agent = BuiltInAgents.repoInsight

        #expect(agent.isEnabled)
        #expect(agent.toolIDs == [
            "agent_parse_repo_insight_goal",
            "context_select_repo",
            "external_search",
            "artifact_build_repo_insight"
        ])
        #expect(agent.artifactTypes == [.markdown, .log])
    }
}
