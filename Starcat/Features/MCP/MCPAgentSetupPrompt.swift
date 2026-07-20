//
//  MCPAgentSetupPrompt.swift
//  Starcat
//
//  外部 AI Agent 安装指引生成器。
//
//  关键约束：安装文本只描述公开入口，不包含 endpoint、Local API Key 或长期设备 token。
//  配对命令可以携带五分钟、单次有效的 invitation，但最终签发仍需 App 内人工确认。
//

import Foundation

enum MCPAgentSetupPrompt {
    static let skillRepositoryURL = "https://github.com/starcat-app/starcat-skill"
    static let cliRepositoryURL = "https://github.com/starcat-app/starcat-cli"
    static let cliInstallCommand = "curl -fsSL https://github.com/starcat-app/starcat-cli/releases/latest/download/install.sh | sh"
    static let windowsCLIInstallCommand = "irm https://github.com/starcat-app/starcat-cli/releases/latest/download/install.ps1 | iex"
    static let cliVerificationCommand = "starcat doctor"

    static var cliAgentInstall: String {
        String(
            format: String.l10n("settings.mcp.agentSetup.cliPrompt"),
            cliRepositoryURL,
            cliInstallCommand,
            windowsCLIInstallCommand
        )
    }

    static var claudeMCPConfiguration: String {
        makeClaudeMCPConfiguration(command: cliExecutablePath)
    }

    static var codexMCPConfiguration: String {
        makeCodexMCPConfiguration(command: cliExecutablePath)
    }

    static var mcpAgentSetup: String {
        String(
            format: String.l10n("settings.mcp.agentSetup.mcpPrompt"),
            cliInstallCommand,
            windowsCLIInstallCommand
        )
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
        String(
            format: String.l10n("settings.mcp.agentSetup.pairPrompt"),
            pairingCommand(invitationURI: invitationURI)
        )
    }

    /// 生成可直接粘贴到 macOS/Linux/Windows 常见 shell 的配对命令。
    /// invitation 由 URLComponents 生成，只包含 URL 安全字符；双引号用于保护 `&`，
    /// 避免 shell 把 query 拆成后台命令。
    static func pairingCommand(invitationURI: String) -> String {
        "starcat pair \"\(invitationURI)\""
    }

    /// Claude Code 的手工配置使用 JSON；`type` 显式声明为 stdio，避免用户把它误解为 HTTP endpoint。
    static func makeClaudeMCPConfiguration(command: String) -> String {
        """
        {
          "mcpServers": {
            "starcat": {
              "type": "stdio",
              "command": \(quotedConfigurationString(command)),
              "args": ["mcp"]
            }
          }
        }
        """
    }

    /// Codex 从 `config.toml` 中是否存在 `command` / `url` 推断 stdio / HTTP，不能写伪造的 transport 字段。
    static func makeCodexMCPConfiguration(command: String) -> String {
        """
        [mcp_servers.starcat]
        command = \(quotedConfigurationString(command))
        args = ["mcp"]
        """
    }

    /// GUI App 从 Finder 启动时继承的 PATH 往往不包含 Homebrew 或 `~/.local/bin`。
    /// 因此除了尊重当前 PATH，还要覆盖 Starcat CLI 官方安装器和 Homebrew 的默认目录，
    /// 让复制出的配置尽可能直接包含 MCP 客户端可执行的绝对路径。
    private static var cliExecutablePath: String {
        let fileManager = FileManager.default
        let pathCandidates = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("starcat").path } ?? []
        let commonCandidates = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/starcat")
                .path,
            "/opt/homebrew/bin/starcat",
            "/usr/local/bin/starcat",
        ]

        return (pathCandidates + commonCandidates)
            .first(where: fileManager.isExecutableFile(atPath:)) ?? "starcat"
    }

    /// JSON 字符串字面量同样是合法的 TOML basic string；统一编码可正确处理路径里的引号和反斜杠。
    private static func quotedConfigurationString(_ value: String) -> String {
        let encoder = JSONEncoder()
        // TOML 不支持 JSON 的 `\/` 转义，因此显式保留路径中的普通斜杠。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try? encoder.encode(value)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"starcat\""
    }
}
