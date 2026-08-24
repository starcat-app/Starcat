//
//  ExternalAgentDefinitions.swift
//  Starcat
//
//  Direct 渠道使用的多后端 General / Research Agent 定义。
//
//  这两个定义不进入 `BuiltInAgents.all`，由 Workspace 根据发行渠道追加展示。
//  ID 保留 POC 阶段的历史值，确保升级后既有任务记录仍能恢复到正确 Agent。
//

import Foundation

enum ExternalAgentDefinitions {
    static var all: [AgentDefinition] {
        [general, research]
    }

    static var general: AgentDefinition {
        AgentDefinition(
            id: "external-general-poc",
            title: String.l10n("agent.definition.general.title"),
            subtitle: String.l10n("agent.definition.general.subtitle"),
            systemImage: "terminal",
            capabilityLabels: [
                String.l10n("agent.capability.externalRuntime"),
                String.l10n("agent.capability.readOnly"),
                String.l10n("agent.capability.session")
            ],
            defaultPrompt: String.l10n("agent.definition.general.defaultPrompt"),
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
            artifactTitle: String.l10n("agent.definition.general.artifactTitle"),
            runtimePolicy: .externalReadOnly,
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
            title: String.l10n("agent.definition.research.title"),
            subtitle: String.l10n("agent.definition.research.subtitle"),
            systemImage: "books.vertical",
            capabilityLabels: [
                String.l10n("agent.capability.research"),
                String.l10n("agent.capability.repositories"),
                String.l10n("agent.capability.readOnly")
            ],
            defaultPrompt: String.l10n("agent.definition.research.defaultPrompt"),
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
            artifactTitle: String.l10n("agent.definition.research.artifactTitle"),
            runtimePolicy: .externalReadOnly,
            artifactTypes: [.markdown]
        )
    }
}
