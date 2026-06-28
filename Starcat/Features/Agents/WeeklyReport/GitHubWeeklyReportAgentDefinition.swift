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
