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
    /// 使用计算属性而不是进程级静态缓存，切换 App 语言后可重新解析标题与默认提示词。
    static var githubWeeklyReport: AgentDefinition { AgentDefinition(
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
        workflow: AgentWorkflowPolicy(
            repositoryContext: .weeklyHotspots(days: 7),
            executionMode: .reportGeneration,
            allowsManualRepositoryOverride: true,
            allowsEmptyRepositoryContext: true,
            usesDefaultPromptWhenEmpty: true,
            maximumSelectedRepositories: 30
        ),
        promptRules: [
            AgentPromptRule(
                id: "weekly-local-facts",
                content: "Treat repository IDs, source IDs, observation timestamps, and metadata in Frozen Starcat Context as the only local facts. The default context comes from Starcat's Weekly multi-source catalog and does not require repositories to be starred. Use knowledge_search only for the eligible indexed subset and cite only its supplied [S#] markers. Do not claim live GitHub trends, releases, or activity unless a network tool result provides that evidence."
            ),
            AgentPromptRule(
                id: "weekly-artifact-contract",
                content: "Use context_resolve_repos and repo_cluster_topics as needed, then submit exactly one structured artifact_build_weekly_report call. An empty sections array is valid only when the frozen Weekly hotspot context is empty."
            )
        ],
        artifactTitle: String.l10n("agent.runtime.artifact.weeklyReport.title"),
        runtimePolicy: .codexReadOnly,
        loopMaxToolCalls: 96,
        toolIDs: [
            "agent_parse_goal",
            "context_resolve_repos",
            "knowledge_search",
            "external_search",
            "repo_cluster_topics",
            "artifact_build_weekly_report"
        ],
        artifactTypes: [.markdown]
    ) }

    static var repoInsight: AgentDefinition { AgentDefinition(
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
        workflow: AgentWorkflowPolicy(
            repositoryContext: .singleRepository,
            executionMode: .reportGeneration,
            allowsManualRepositoryOverride: true,
            allowsEmptyRepositoryContext: false,
            usesDefaultPromptWhenEmpty: true,
            maximumSelectedRepositories: 1
        ),
        promptRules: [
            AgentPromptRule(
                id: "repo-insight-selection",
                content: "The frozen business context contains exactly one target repository. Base repository facts only on that snapshot; use knowledge_search only when the target is in the eligible indexed subset and preserve supplied [S#] citations."
            ),
            AgentPromptRule(
                id: "repo-insight-artifact-contract",
                content: "Submit exactly one structured artifact_build_repo_insight call. State missing README, license, maintenance, or live activity evidence as limitations rather than inventing it."
            )
        ],
        runtimePolicy: .codexReadOnly,
        loopMaxToolCalls: 96,
        toolIDs: [
            "agent_parse_repo_insight_goal",
            "context_select_repo",
            "knowledge_search",
            "external_search",
            "artifact_build_repo_insight"
        ],
        artifactTypes: [.markdown]
    ) }

    static var repoAlternatives: AgentDefinition { AgentDefinition(
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
        isEnabled: true,
        workflow: AgentWorkflowPolicy(
            repositoryContext: .singleRepository,
            executionMode: .reportGeneration,
            allowsManualRepositoryOverride: true,
            allowsEmptyRepositoryContext: false,
            usesDefaultPromptWhenEmpty: true,
            maximumSelectedRepositories: 1
        ),
        promptRules: [
            AgentPromptRule(
                id: "repo-alternatives-source",
                content: "The frozen business context contains exactly one source repository. Base source facts only on that snapshot. Use knowledge_search only for the eligible indexed source repository and preserve supplied [S#] citations."
            ),
            AgentPromptRule(
                id: "repo-alternatives-evidence",
                content: "Discover candidate repositories only through external_search with allowedDomains=[\"github.com\"]. Do not invent candidates, stars, licenses, maintenance status, or activity. A candidate fullName and root GitHub URL must appear in the returned External Search evidence."
            ),
            AgentPromptRule(
                id: "repo-alternatives-artifact-contract",
                content: "Select the frozen source repository before searching, then submit exactly one structured artifact_build_repo_alternatives call. Use at most 6 candidates. If External Search is unavailable or yields no verified candidate, submit an empty candidates array and state that limitation."
            )
        ],
        runtimePolicy: .codexReadOnly,
        loopMaxToolCalls: 96,
        toolIDs: [
            "agent_parse_repo_alternatives_goal",
            "context_select_repo",
            "knowledge_search",
            "external_search",
            "artifact_build_repo_alternatives"
        ],
        artifactTypes: [.markdown]
    ) }

    static var untaggedTidy: AgentDefinition { AgentDefinition(
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
        isEnabled: true,
        workflow: AgentWorkflowPolicy(
            repositoryContext: .selectedRepositories,
            executionMode: .approvedAction,
            allowsManualRepositoryOverride: true,
            allowsEmptyRepositoryContext: false,
            usesDefaultPromptWhenEmpty: true,
            maximumSelectedRepositories: 30
        ),
        promptRules: [
            AgentPromptRule(
                id: "untagged-explicit-scope",
                content: "Operate only on repositories in Frozen Starcat Context. First call tag_inspect_untagged. Repositories must exist in the local repos table and still have no tags. Never add a repository to Starcat, star it, or expand the frozen scope."
            ),
            AgentPromptRule(
                id: "untagged-existing-taxonomy",
                content: "Suggest only exact existing tag names returned by tag_inspect_untagged. Do not create, rename, merge, or delete tags. Use knowledge_search only for the eligible subset when additional repository evidence is needed."
            ),
            AgentPromptRule(
                id: "untagged-preview-approval",
                content: "Call tag_preview_untagged with the complete proposed diff before any write. Then call tag_apply_untagged with the exact same assignments and preview_hash. The apply tool requires explicit user confirmation and performs read-back verification."
            )
        ],
        toolIDs: [
            "tag_inspect_untagged",
            "knowledge_search",
            "tag_preview_untagged",
            "tag_apply_untagged"
        ],
        artifactTypes: [.markdown]
    ) }

    static var all: [AgentDefinition] { [
        githubWeeklyReport,
        repoInsight,
        repoAlternatives,
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
        untaggedTidy,
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
    ] }
}
