//
//  AgentDefinitionTests.swift
//  StarcatTests
//
//  内置 Agent 定义契约测试。
//
//  `toolIDs` 是当前 Agent 暴露给模型的 allowlist,不表示固定执行顺序。
//  这里锁住定义层,避免后续改 UI 文案时误删工具或声明不存在的产物。
//

import Testing
@testable import Starcat

@Suite("AgentDefinition")
struct AgentDefinitionTests {

    @Test("Weekly Agent 声明正式工具 allowlist 和产物类型")
    func weeklyAgentDeclaresToolAllowlist() {
        let agent = BuiltInAgents.githubWeeklyReport

        #expect(agent.toolIDs == [
            "agent_parse_goal",
            "context_resolve_repos",
            "knowledge_search",
            "external_search",
            "repo_cluster_topics",
            "artifact_build_weekly_report"
        ])
        #expect(agent.artifactTypes == [.markdown])
    }

    @Test("Repo Insight Agent 声明只读工具 allowlist 并默认启用")
    func repoInsightDeclaresToolAllowlist() {
        let agent = BuiltInAgents.repoInsight

        #expect(agent.isEnabled)
        #expect(agent.toolIDs == [
            "agent_parse_repo_insight_goal",
            "context_select_repo",
            "knowledge_search",
            "external_search",
            "artifact_build_repo_insight"
        ])
        #expect(agent.artifactTypes == [.markdown])
    }
}
