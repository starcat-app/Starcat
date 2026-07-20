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
    static let cliInstallCommand = "curl -fsSL https://github.com/dong4j/starcat-cli/releases/latest/download/install.sh | sh"
    static let cliVerificationCommand = "starcat doctor --json"

    static var cliAgentInstall: String {
        String(format: String.l10n("settings.mcp.agentSetup.cliPrompt"), cliRepositoryURL)
    }

    static var mcpManualSetup: String {
        String.l10n("settings.mcp.agentSetup.mcpManualPrompt")
    }

    static var mcpAgentSetup: String {
        String.l10n("settings.mcp.agentSetup.mcpPrompt")
    }

    static var skillManualInstall: String {
        String(
            format: String.l10n("settings.mcp.agentSetup.skillManualPrompt"),
            skillRepositoryURL
        )
    }

    static var skillAgentInstall: String {
        String(
            format: String.l10n("settings.mcp.agentSetup.skillPrompt"),
            skillRepositoryURL
        )
    }

    static func pairAgent(invitationURI: String) -> String {
        String(format: String.l10n("settings.mcp.agentSetup.pairPrompt"), invitationURI)
    }
}
