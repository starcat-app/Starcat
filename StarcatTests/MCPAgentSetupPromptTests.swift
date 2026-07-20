//
//  MCPAgentSetupPromptTests.swift
//  StarcatTests
//
//  验证复制给外部 Agent 的安装文本只包含公开安装信息，不泄露连接凭据。
//

import Testing
@testable import Starcat

@Suite("MCP Agent Setup Prompt")
struct MCPAgentSetupPromptTests {
    @Test("MCP prompt 通过 Go CLI 配置且不包含 endpoint 或 key")
    func mcpAgentPromptUsesCLIWithoutCredentials() {
        let prompt = MCPAgentSetupPrompt.mcpAgentSetup

        #expect(prompt.contains("starcat mcp"))
        #expect(prompt.contains("starcat pair --stdin"))
        #expect(prompt.contains("starcat.get_capabilities"))
        #expect(!prompt.contains("127.0.0.1"))
        #expect(!prompt.contains("Bearer"))
        #expect(!prompt.contains("Authorization:"))
    }

    @Test("CLI 手工安装和检测命令保持可直接执行")
    func cliManualCommandsStayExecutable() {
        #expect(MCPAgentSetupPrompt.cliInstallCommand.contains("releases/latest/download/install.sh"))
        #expect(MCPAgentSetupPrompt.cliInstallCommand.hasSuffix("| sh"))
        #expect(MCPAgentSetupPrompt.cliVerificationCommand == "starcat doctor --json")
    }

    @Test("CLI Agent prompt 指向公开 Go CLI 仓库")
    func cliAgentPromptUsesPublicRepository() {
        let prompt = MCPAgentSetupPrompt.cliAgentInstall

        #expect(prompt.contains("starcat-cli"))
        #expect(prompt.contains(MCPAgentSetupPrompt.cliRepositoryURL))
        #expect(prompt.contains("brew tap starcat-app/starcat-cli"))
    }

    @Test("MCP 手工说明包含 stdio 配置且不包含凭据")
    func mcpManualSetupUsesAbsoluteCLIPathWithoutCredentials() {
        let prompt = MCPAgentSetupPrompt.mcpManualSetup

        #expect(prompt.contains("command -v starcat"))
        #expect(prompt.contains("[\"mcp\"]"))
        #expect(!prompt.contains("Bearer"))
        #expect(!prompt.contains("Authorization:"))
    }

    @Test("Skill 手工说明覆盖 Codex 与 Claude Code 用户目录")
    func skillManualSetupCoversSupportedAgents() {
        let prompt = MCPAgentSetupPrompt.skillManualInstall

        #expect(prompt.contains(MCPAgentSetupPrompt.skillRepositoryURL))
        #expect(prompt.contains(".codex/skills/starcat-skill"))
        #expect(prompt.contains(".claude/skills/starcat-skill"))
    }

    @Test("Skill Agent prompt 只包含安装请求和公开仓库地址")
    func skillAgentPromptStaysConcise() {
        let prompt = MCPAgentSetupPrompt.skillAgentInstall

        #expect(prompt.contains("starcat-skill"))
        #expect(prompt.contains(MCPAgentSetupPrompt.skillRepositoryURL))
        #expect(prompt.split(separator: "\n").count == 1)
    }

    @Test("配对 prompt 只通过 stdin 传递一次性 URI")
    func pairingPromptUsesStandardInput() {
        let invitation = "starcat-pair://connect?v=1&secret=temporary"
        let prompt = MCPAgentSetupPrompt.pairAgent(invitationURI: invitation)

        #expect(prompt.contains("starcat pair --stdin"))
        #expect(prompt.contains(invitation))
        #expect(!prompt.contains("starcat pair \"\(invitation)\""))
    }
}
