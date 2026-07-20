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
    func mcpPromptUsesCLIWithoutCredentials() {
        let prompt = MCPAgentSetupPrompt.mcp

        #expect(prompt.contains("starcat mcp"))
        #expect(prompt.contains("starcat pair --stdin"))
        #expect(prompt.contains("starcat.get_capabilities"))
        #expect(!prompt.contains("127.0.0.1"))
        #expect(!prompt.contains("Bearer"))
        #expect(!prompt.contains("Authorization:"))
    }

    @Test("CLI prompt 指向公开 Go CLI 仓库")
    func cliPromptUsesPublicRepository() {
        let prompt = MCPAgentSetupPrompt.cliInstall

        #expect(prompt.contains("starcat-cli"))
        #expect(prompt.contains(MCPAgentSetupPrompt.cliRepositoryURL))
        #expect(prompt.contains("brew tap dong4j/starcat-cli"))
    }

    @Test("Skill prompt 只包含安装请求和公开仓库地址")
    func skillPromptStaysConcise() {
        let prompt = MCPAgentSetupPrompt.skillInstall

        #expect(prompt.contains("starcat-skill"))
        #expect(prompt.contains(MCPAgentSetupPrompt.skillRepositoryURL))
        #expect(prompt.split(separator: "\n").count == 1)
    }

    @Test("配对 prompt 只通过 stdin 传递一次性 URI")
    func pairingPromptUsesStandardInput() {
        let invitation = "starcat-pair://connect?v=1&secret=temporary"
        let prompt = MCPAgentSetupPrompt.pair(invitationURI: invitation)

        #expect(prompt.contains("starcat pair --stdin"))
        #expect(prompt.contains(invitation))
        #expect(!prompt.contains("starcat pair \"\(invitation)\""))
    }
}
