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
        capabilityLabels: ["trending", "report", "artifact"],
        defaultPrompt: String.l10n("agent.definition.githubWeeklyReport.defaultPrompt"),
        isEnabled: true,
        toolIDs: [
            "agent.parseGoal",
            "context.resolveRepos",
            "external.search",
            "report.clusterTopics",
            "artifact.buildMarkdown"
        ],
        artifactTypes: [.markdown, .log]
    )

    static let all: [AgentDefinition] = [
        githubWeeklyReport,
        AgentDefinition(
            id: "repo-alternatives",
            title: String.l10n("agent.definition.repoAlternatives.title"),
            subtitle: String.l10n("agent.definition.repoAlternatives.subtitle"),
            systemImage: "arrow.triangle.branch",
            capabilityLabels: ["compare", "github", "table"],
            defaultPrompt: String.l10n("agent.definition.repoAlternatives.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "overlap-scan",
            title: String.l10n("agent.definition.overlapScan.title"),
            subtitle: String.l10n("agent.definition.overlapScan.subtitle"),
            systemImage: "rectangle.3.group",
            capabilityLabels: ["cluster", "cleanup", "confirm"],
            defaultPrompt: String.l10n("agent.definition.overlapScan.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "recall-search",
            title: String.l10n("agent.definition.recallSearch.title"),
            subtitle: String.l10n("agent.definition.recallSearch.subtitle"),
            systemImage: "quote.bubble",
            capabilityLabels: ["fts", "semantic", "citation"],
            defaultPrompt: String.l10n("agent.definition.recallSearch.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "untagged-tidy",
            title: String.l10n("agent.definition.untaggedTidy.title"),
            subtitle: String.l10n("agent.definition.untaggedTidy.subtitle"),
            systemImage: "tag",
            capabilityLabels: ["taxonomy", "queue", "review"],
            defaultPrompt: String.l10n("agent.definition.untaggedTidy.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "repo-insight",
            title: String.l10n("agent.definition.repoInsight.title"),
            subtitle: String.l10n("agent.definition.repoInsight.subtitle"),
            systemImage: "doc.text.magnifyingglass",
            capabilityLabels: ["repo", "analysis"],
            defaultPrompt: String.l10n("agent.definition.repoInsight.defaultPrompt"),
            isEnabled: false
        ),
        AgentDefinition(
            id: "release-watcher",
            title: String.l10n("agent.definition.releaseWatcher.title"),
            subtitle: String.l10n("agent.definition.releaseWatcher.subtitle"),
            systemImage: "bell.badge",
            capabilityLabels: ["release", "watch"],
            defaultPrompt: String.l10n("agent.definition.releaseWatcher.defaultPrompt"),
            isEnabled: false
        )
    ]
}
