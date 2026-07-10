//
//  GitHubWeeklyReportAgentDefinition.swift
//  Starcat
//
//  GitHub Weekly Report 内置 Agent 定义。
//
//  这里先只声明 Agent 能力与默认提示词。真正的数据读取、工具调用与 artifact 生成
//  通过 AgentRuntime 执行，避免把具体 Agent 和 Workspace UI 耦合在一起。
//

import Foundation

enum BuiltInAgents {
    static let githubWeeklyReport = AgentDefinition(
        id: "github-weekly-report",
        title: String.l10n("agent.definition.githubWeeklyReport.title"),
        subtitle: String.l10n("agent.definition.githubWeeklyReport.subtitle"),
        systemImage: "newspaper",
        capabilityLabels: [
            String.l10n("agent.capability.trending"),
            String.l10n("agent.capability.report"),
            String.l10n("agent.capability.artifact")
        ],
        defaultPrompt: String.l10n("agent.definition.githubWeeklyReport.defaultPrompt"),
        isEnabled: true,
        toolIDs: [
            "agent_parse_goal",
            "context_resolve_repos",
            "external_search",
            "repo_cluster_topics",
            "artifact_build_weekly_report"
        ],
        artifactTypes: [.markdown, .log]
    )

    static let repoInsight = AgentDefinition(
        id: "repo-insight",
        title: String.l10n("agent.definition.repoInsight.title"),
        subtitle: String.l10n("agent.definition.repoInsight.subtitle"),
        systemImage: "doc.text.magnifyingglass",
        capabilityLabels: [
            String.l10n("agent.capability.repository"),
            String.l10n("agent.capability.analysis"),
            String.l10n("agent.capability.artifact")
        ],
        defaultPrompt: String.l10n("agent.definition.repoInsight.defaultPrompt"),
        isEnabled: true,
        toolIDs: [
            "agent_parse_repo_insight_goal",
            "context_select_repo",
            "external_search",
            "artifact_build_repo_insight"
        ],
        artifactTypes: [.markdown, .log]
    )

    static let all: [AgentDefinition] = [
        githubWeeklyReport,
        repoInsight,
        AgentDefinition(
            id: "repo-alternatives",
            title: String.l10n("agent.definition.repoAlternatives.title"),
            subtitle: String.l10n("agent.definition.repoAlternatives.subtitle"),
            systemImage: "arrow.triangle.branch",
            capabilityLabels: [
                String.l10n("agent.capability.compare"),
                String.l10n("agent.capability.github"),
                String.l10n("agent.capability.table")
            ],
            defaultPrompt: String.l10n("agent.definition.repoAlternatives.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "overlap-scan",
            title: String.l10n("agent.definition.overlapScan.title"),
            subtitle: String.l10n("agent.definition.overlapScan.subtitle"),
            systemImage: "rectangle.3.group",
            capabilityLabels: [
                String.l10n("agent.capability.cluster"),
                String.l10n("agent.capability.cleanup"),
                String.l10n("agent.capability.confirm")
            ],
            defaultPrompt: String.l10n("agent.definition.overlapScan.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "recall-search",
            title: String.l10n("agent.definition.recallSearch.title"),
            subtitle: String.l10n("agent.definition.recallSearch.subtitle"),
            systemImage: "quote.bubble",
            capabilityLabels: [
                String.l10n("agent.capability.fts"),
                String.l10n("agent.capability.semantic"),
                String.l10n("agent.capability.citation")
            ],
            defaultPrompt: String.l10n("agent.definition.recallSearch.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "untagged-tidy",
            title: String.l10n("agent.definition.untaggedTidy.title"),
            subtitle: String.l10n("agent.definition.untaggedTidy.subtitle"),
            systemImage: "tag",
            capabilityLabels: [
                String.l10n("agent.capability.taxonomy"),
                String.l10n("agent.capability.queue"),
                String.l10n("agent.capability.review")
            ],
            defaultPrompt: String.l10n("agent.definition.untaggedTidy.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "release-watcher",
            title: String.l10n("agent.definition.releaseWatcher.title"),
            subtitle: String.l10n("agent.definition.releaseWatcher.subtitle"),
            systemImage: "bell.badge",
            capabilityLabels: [
                String.l10n("agent.capability.release"),
                String.l10n("agent.capability.watch")
            ],
            defaultPrompt: String.l10n("agent.definition.releaseWatcher.defaultPrompt"),
            isEnabled: false
        )
    ]
}
