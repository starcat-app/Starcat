//
//  ExternalAgentPOCAgentDefinitions.swift
//  Starcat
//
//  Direct Debug 构建中用于验证多后端路由的 General / Research Agent 定义。
//
//  这两个定义不进入 `BuiltInAgents.all`，因此 Release、App Store 和现有 Agent
//  测试基线不会被 POC 污染。只有显式选择外部 backend 后 Workspace 才追加展示。
//

import Foundation

enum ExternalAgentPOCAgentDefinitions {
    static var all: [AgentDefinition] {
        [general, research]
    }

    static var general: AgentDefinition {
        AgentDefinition(
            id: "external-general-poc",
            title: "General Agent (POC)",
            subtitle: "验证 Codex / DeepSeek 可切换 Runtime 与原生 Run Surface",
            systemImage: "terminal",
            capabilityLabels: ["External", "Read-only", "Session"],
            defaultPrompt: "请根据提供的 Starcat 上下文回答问题。",
            isEnabled: true,
            workflow: AgentWorkflowPolicy(
                repositoryContext: .none,
                executionMode: .readonlyPlanning,
                allowsManualRepositoryOverride: false,
                allowsEmptyRepositoryContext: true,
                usesDefaultPromptWhenEmpty: false,
                maximumSelectedRepositories: 0
            ),
            promptRules: [
                AgentPromptRule(
                    id: "external-general-readonly",
                    content: "Remain read-only. Use the Starcat MCP tools for repository questions. Do not use shell, filesystem mutation, browser automation, or subagents."
                )
            ],
            artifactTitle: "External Agent Result",
            runtimePolicy: .externalPOC,
            externalMCPToolIDs: [
                "starcat.get_overview_statistics",
                "starcat.search_repos",
                "starcat.get_repo",
                "starcat.get_repo_context",
                "starcat.get_repo_summary",
                "starcat.get_readme",
                "starcat.list_tags",
            ],
            artifactTypes: [.markdown]
        )
    }

    static var research: AgentDefinition {
        AgentDefinition(
            id: "external-research-poc",
            title: "Research Agent (POC)",
            subtitle: "基于显式冻结仓库上下文验证外部长期 Session",
            systemImage: "books.vertical",
            capabilityLabels: ["Research", "Repositories", "Read-only"],
            defaultPrompt: "请比较所选仓库并给出有依据的研究结论。",
            isEnabled: true,
            workflow: AgentWorkflowPolicy(
                repositoryContext: .selectedRepositories,
                executionMode: .readonlyPlanning,
                allowsManualRepositoryOverride: true,
                allowsEmptyRepositoryContext: false,
                usesDefaultPromptWhenEmpty: false,
                maximumSelectedRepositories: 12
            ),
            promptRules: [
                AgentPromptRule(
                    id: "external-research-frozen-context",
                    content: "Treat Frozen Starcat Context as the complete repository scope. State missing evidence instead of inventing facts."
                )
            ],
            artifactTitle: "External Research Result",
            runtimePolicy: .externalPOC,
            artifactTypes: [.markdown]
        )
    }
}
