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
        title: "GitHub Weekly Report",
        subtitle: "整理热门开源项目并生成技术周刊",
        systemImage: "newspaper",
        capabilityLabels: ["trending", "report", "artifact"],
        defaultPrompt: "帮我生成本周 GitHub 热门开源项目周刊，风格参考阮一峰 Weekly。",
        isEnabled: true
    )

    static let all: [AgentDefinition] = [
        githubWeeklyReport,
        AgentDefinition(
            id: "repo-alternatives",
            title: "替代品发现",
            subtitle: "从当前 repo 出发寻找更活跃的同类项目",
            systemImage: "arrow.triangle.branch",
            capabilityLabels: ["compare", "github", "table"],
            defaultPrompt: "帮我基于当前仓库找 3-5 个更活跃的同类替代品，并生成对比表。",
            isEnabled: false
        ),
        AgentDefinition(
            id: "overlap-scan",
            title: "重叠扫描",
            subtitle: "扫描已 star 仓库中的功能重叠簇",
            systemImage: "rectangle.3.group",
            capabilityLabels: ["cluster", "cleanup", "confirm"],
            defaultPrompt: "扫描我已 star 的仓库，找出功能重叠的项目组，先给建议，不要自动修改。",
            isEnabled: false
        ),
        AgentDefinition(
            id: "recall-search",
            title: "回忆搜索",
            subtitle: "用证据引用找回曾经 star 过的项目",
            systemImage: "quote.bubble",
            capabilityLabels: ["fts", "semantic", "citation"],
            defaultPrompt: "帮我找回之前 star 过、适合做本地文档 RAG 的 Swift 项目。",
            isEnabled: false
        ),
        AgentDefinition(
            id: "untagged-tidy",
            title: "Untagged 整理",
            subtitle: "规划 tag 体系并批量整理未分类仓库",
            systemImage: "tag",
            capabilityLabels: ["taxonomy", "queue", "review"],
            defaultPrompt: "帮我给未分类的 starred repo 规划一套 tag 体系，先预览，不要自动写入。",
            isEnabled: false
        ),
        AgentDefinition(
            id: "repo-insight",
            title: "Repo Insight",
            subtitle: "单仓库深度解读与采用建议",
            systemImage: "doc.text.magnifyingglass",
            capabilityLabels: ["repo", "analysis"],
            defaultPrompt: "帮我解读当前仓库的定位、亮点和风险。",
            isEnabled: false
        ),
        AgentDefinition(
            id: "release-watcher",
            title: "Release Watcher",
            subtitle: "整理 Release 变化并分析影响",
            systemImage: "bell.badge",
            capabilityLabels: ["release", "watch"],
            defaultPrompt: "帮我整理最近 Release 的重要变化。",
            isEnabled: false
        )
    ]
}
