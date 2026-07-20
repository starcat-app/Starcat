//
//  MCPAgentSetupPromptTests.swift
//  StarcatTests
//
//  验证复制给外部 Agent 的安装文本只包含公开安装信息，不泄露连接凭据。
//

import Foundation
import Testing
@testable import Starcat

@Suite("MCP Agent Setup Prompt")
struct MCPAgentSetupPromptTests {
    @Test("MCP prompt 通过 Go CLI 配置且不包含 endpoint 或 key")
    func mcpAgentPromptUsesCLIWithoutCredentials() {
        let prompt = MCPAgentSetupPrompt.mcpAgentSetup

        #expect(prompt.contains("starcat mcp"))
        #expect(prompt.contains("starcat doctor"))
        #expect(prompt.contains("starcat pair"))
        #expect(prompt.contains(MCPAgentSetupPrompt.cliInstallCommand))
        #expect(prompt.contains("$HOME/.local/bin/starcat"))
        #expect(!prompt.contains("--stdin"))
        #expect(prompt.contains("starcat.get_capabilities"))
        #expect(!prompt.contains("127.0.0.1"))
        #expect(!prompt.contains("Authorization:"))
    }

    @Test("CLI 手工安装和检测命令保持可直接执行")
    func cliManualCommandsStayExecutable() {
        #expect(MCPAgentSetupPrompt.cliInstallCommand.contains("releases/latest/download/install.sh"))
        #expect(MCPAgentSetupPrompt.cliInstallCommand.hasSuffix("| sh"))
        #expect(MCPAgentSetupPrompt.windowsCLIInstallCommand.contains("releases/latest/download/install.ps1"))
        #expect(MCPAgentSetupPrompt.windowsCLIInstallCommand.hasSuffix("| iex"))
        #expect(MCPAgentSetupPrompt.cliVerificationCommand == "starcat doctor")
    }

    @Test("CLI Agent prompt 指向公开 Go CLI 仓库")
    func cliAgentPromptUsesPublicRepository() {
        let prompt = MCPAgentSetupPrompt.cliAgentInstall

        #expect(prompt.contains("starcat-cli"))
        #expect(prompt.contains(MCPAgentSetupPrompt.cliRepositoryURL))
        #expect(prompt.contains(MCPAgentSetupPrompt.cliInstallCommand))
        #expect(prompt.contains(MCPAgentSetupPrompt.windowsCLIInstallCommand))
        #expect(prompt.contains("\"$HOME/.local/bin/starcat\" doctor"))
        #expect(!prompt.contains("api.github.com"))
    }

    @Test("Claude MCP 配置是显式 stdio JSON 且不包含凭据")
    func claudeMCPConfigurationUsesJSONWithoutCredentials() throws {
        let configuration = MCPAgentSetupPrompt.makeClaudeMCPConfiguration(
            command: "/Users/example/.local/bin/starcat"
        )
        let data = try #require(configuration.data(using: .utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let starcat = try #require(servers["starcat"] as? [String: Any])

        #expect(starcat["type"] as? String == "stdio")
        #expect(starcat["command"] as? String == "/Users/example/.local/bin/starcat")
        #expect(starcat["args"] as? [String] == ["mcp"])
        #expect(!configuration.contains("Bearer"))
        #expect(!configuration.contains("Authorization:"))
        #expect(!configuration.contains("endpoint"))
    }

    @Test("Codex MCP 配置使用原生 TOML 且不添加 transport")
    func codexMCPConfigurationUsesNativeTOMLWithoutCredentials() {
        let configuration = MCPAgentSetupPrompt.makeCodexMCPConfiguration(
            command: "/Users/example/.local/bin/starcat"
        )

        #expect(configuration.contains("[mcp_servers.starcat]"))
        #expect(configuration.contains("command = \"/Users/example/.local/bin/starcat\""))
        #expect(configuration.contains("args = [\"mcp\"]"))
        #expect(!configuration.contains("transport"))
        #expect(!configuration.contains("Bearer"))
        #expect(!configuration.contains("Authorization:"))
        #expect(!configuration.contains("endpoint"))
    }

    @Test("Skill 手工说明覆盖 Codex 与 Claude Code 用户目录")
    func skillManualSetupCoversSupportedAgents() {
        let prompt = MCPAgentSetupPrompt.skillManualInstall

        #expect(prompt.contains(MCPAgentSetupPrompt.skillRepositoryURL))
        #expect(prompt.contains(".codex/skills/starcat-skill"))
        #expect(prompt.contains(".claude/skills/starcat-skill"))
        #expect(prompt.contains("$starcat-skill"))
    }

    @Test("四类 Agent prompt 使用结构化 Markdown 且角色描述明确")
    func agentPromptsUseStructuredMarkdownWithExplicitRoles() {
        let invitation = "starcat-pair://connect?v=1&secret=temporary"
        let prompts = [
            MCPAgentSetupPrompt.cliAgentInstall,
            MCPAgentSetupPrompt.pairAgent(invitationURI: invitation),
            MCPAgentSetupPrompt.mcpAgentSetup,
            MCPAgentSetupPrompt.skillAgentInstall,
        ]

        for prompt in prompts {
            #expect(prompt.hasPrefix("# "))
            #expect(prompt.components(separatedBy: "\n## ").count >= 4)
            #expect(prompt.contains("```"))
            #expect(prompt.contains("AI Agent"))
            #expect(!prompt.contains("本消息就是"))
            #expect(!prompt.contains("The user has reviewed"))
            #expect(!prompt.contains("请让我"))
            #expect(!prompt.contains("ask me"))
        }
    }

    @Test("Skill Agent prompt 覆盖安装、重载和只读验证")
    func skillAgentPromptCoversInstallationAndVerification() {
        let prompt = MCPAgentSetupPrompt.skillAgentInstall

        #expect(prompt.contains("starcat-skill"))
        #expect(prompt.contains(MCPAgentSetupPrompt.skillRepositoryURL))
        #expect(prompt.contains(".codex/skills/starcat-skill"))
        #expect(prompt.contains(".claude/skills/starcat-skill"))
        #expect(prompt.contains("pull --ff-only"))
        #expect(prompt.contains("starcat --help"))
        #expect(prompt.contains("$starcat-skill"))
    }

    @Test("配对命令包含单次 URI 且可直接粘贴执行")
    func pairingPromptContainsExecutableCommand() {
        let invitation = "starcat-pair://connect?v=1&secret=temporary"
        let prompt = MCPAgentSetupPrompt.pairAgent(invitationURI: invitation)

        #expect(prompt.contains("starcat pair \"\(invitation)\""))
        #expect(prompt.contains(invitation))
        #expect(!prompt.contains("--stdin"))
    }

    @Test("配对 URI query 被双引号保护")
    func pairingCommandQuotesQuery() {
        let invitation = "starcat-pair://connect?v=1&endpoint=https%3A%2F%2Fstudio.local%3A5555%2Fmcp&secret=temporary"
        #expect(MCPAgentSetupPrompt.pairingCommand(invitationURI: invitation) == "starcat pair \"\(invitation)\"")
    }
}
