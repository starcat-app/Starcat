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

    @Test("工作台分类以通用 Agent 开始且每个 Agent 只出现一次")
    func workspaceTaxonomyStartsWithGeneralAgentWithoutDuplicates() throws {
        let definitions = ExternalAgentDefinitions.all + BuiltInAgents.all
        let groupedIDs = AgentWorkspaceTaxonomy.sections.flatMap { section in
            AgentWorkspaceTaxonomy.agents(in: section, from: definitions).map(\.id)
        }

        #expect(groupedIDs.first == "external-general-poc")
        #expect(Set(groupedIDs).count == groupedIDs.count)
        #expect(groupedIDs.contains("github-weekly-report"))
        #expect(groupedIDs.contains("external-research-poc"))
    }

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
        #expect(agent.workflow.repositoryContext == .weeklyHotspots(days: 7))
        #expect(agent.workflow.allowsEmptyRepositoryContext)
        #expect(agent.workflow.allowsManualRepositoryOverride)
        #expect(agent.workflow.usesDefaultPromptWhenEmpty)
        #expect(agent.promptRules.map(\.id) == ["weekly-local-facts", "weekly-artifact-contract"])
        #expect(agent.runtimePolicy == .codexReadOnly)
    }

    @Test("外部 Agent 显式允许 Codex 与 DeepSeek，不进入固定业务 Agent 列表")
    func externalAgentsDeclareSwitchableRuntime() {
        let agent = ExternalAgentDefinitions.general

        #expect(agent.runtimePolicy == .externalReadOnly)
        #expect(agent.runtimePolicy.allowedBackends == [.codexAppServer, .deepSeekHarness])
        #expect(agent.externalMCPToolIDs == [
            "starcat.get_overview_statistics",
            "starcat.search_repos",
            "starcat.get_repo",
            "starcat.get_repo_context",
            "starcat.get_repo_summary",
            "starcat.get_readme",
            "starcat.list_tags",
        ])
        #expect(!BuiltInAgents.all.contains(where: { $0.id == agent.id }))
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
        #expect(agent.workflow.repositoryContext == .singleRepository)
        #expect(agent.workflow.maximumSelectedRepositories == 1)
        #expect(!agent.workflow.allowsEmptyRepositoryContext)
        #expect(agent.promptRules.map(\.id) == ["repo-insight-selection", "repo-insight-artifact-contract"])
    }

    @Test("Repo Alternatives Agent 只读取单仓上下文和公开搜索证据")
    func repoAlternativesDeclaresEvidenceBoundToolAllowlist() {
        let agent = BuiltInAgents.repoAlternatives

        #expect(agent.isEnabled)
        #expect(agent.toolIDs == [
            "agent_parse_repo_alternatives_goal",
            "context_select_repo",
            "knowledge_search",
            "external_search",
            "artifact_build_repo_alternatives"
        ])
        #expect(agent.artifactTypes == [.markdown])
        #expect(agent.workflow.repositoryContext == .singleRepository)
        #expect(agent.workflow.maximumSelectedRepositories == 1)
        #expect(!agent.workflow.allowsEmptyRepositoryContext)
        #expect(agent.promptRules.map(\.id) == [
            "repo-alternatives-source",
            "repo-alternatives-evidence",
            "repo-alternatives-artifact-contract"
        ])
    }

    @Test("Untagged Tidy 只操作明确多选仓库并要求审批写入")
    func untaggedTidyDeclaresApprovedActionWorkflow() {
        let agent = BuiltInAgents.untaggedTidy

        #expect(agent.isEnabled)
        #expect(agent.workflow.repositoryContext == .selectedRepositories)
        #expect(agent.workflow.executionMode == .approvedAction)
        #expect(agent.workflow.maximumSelectedRepositories == 30)
        #expect(!agent.workflow.allowsEmptyRepositoryContext)
        #expect(agent.toolIDs == [
            "tag_inspect_untagged",
            "knowledge_search",
            "tag_preview_untagged",
            "tag_apply_untagged"
        ])
        #expect(agent.promptRules.map(\.id) == [
            "untagged-explicit-scope",
            "untagged-existing-taxonomy",
            "untagged-preview-approval"
        ])
    }
}
