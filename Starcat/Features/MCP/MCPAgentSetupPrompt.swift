//
//  MCPAgentSetupPrompt.swift
//  Starcat
//
//  外部 AI Agent 安装指引生成器。
//
//  关键约束：复制文本只描述公开安装入口和 CLI 命令，不包含 endpoint、Local API Key
//  或长期设备 token。连接资料通过一次性 pairing URI 单独交换。
//

import Foundation

enum MCPAgentSetupPrompt {
    static let skillRepositoryURL = "https://github.com/dong4j/starcat-skill"
    static let cliRepositoryURL = "https://github.com/dong4j/starcat-cli"

    static var cliInstall: String {
        String(format: String.l10n("settings.mcp.agentSetup.cliPrompt"), cliRepositoryURL)
    }

    static var mcp: String {
        String.l10n("settings.mcp.agentSetup.mcpPrompt")
    }

    static var skillInstall: String {
        String(
            format: String.l10n("settings.mcp.agentSetup.skillPrompt"),
            skillRepositoryURL
        )
    }

    static func pair(invitationURI: String) -> String {
        String(format: String.l10n("settings.mcp.agentSetup.pairPrompt"), invitationURI)
    }
}
