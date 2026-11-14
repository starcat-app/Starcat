//
//  RepoSkillAgentCatalog.swift
//  Starcat
//
//  用户级 Agent Skills 目录与只读本机检测。目录来源和品牌素材版本见资源中的 SOURCES.md。
//  不运行外部 CLI，不因检测而创建目录；工具与实际安装目录保持独立身份。
//

import Foundation

/// 一个工具的静态配置；普通配置目录必须存在非 skills 内容，防止把导出目录误判成工具安装。
struct RepoSkillAgent: Sendable {
    let name: String
    let directory: String
    let configuration: String
    let command: String?
    let application: String?
    let extensions: [String]
    let logo: String?

    init(_ name: String, _ directory: String, configuration: String? = nil,
         command: String? = nil, application: String? = nil,
         extensions: [String] = [], logo: String? = nil) {
        self.name = name
        self.directory = directory
        self.configuration = configuration ?? (directory as NSString).deletingLastPathComponent
        self.command = command
        self.application = application
        self.extensions = extensions
        self.logo = logo
    }

    /// 环境变量只作为路径读取，不启动 shell；配置目录覆盖同时用于检测与相应的安装根。
    func directoryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        Self.resolve(directory, home: home, environment: environment)
    }

    func configurationURL(home: URL, environment: [String: String]) -> URL {
        Self.resolve(configuration, home: home, environment: environment)
    }

    private static func resolve(_ path: String, home: URL, environment: [String: String]) -> URL {
        let overrides = [
            ("~/.config", "XDG_CONFIG_HOME"), ("~/.claude", "CLAUDE_CONFIG_DIR"),
            ("~/.codex", "CODEX_HOME"), ("~/.vibe", "VIBE_HOME"),
            ("~/.hermes", "HERMES_HOME"), ("~/.autohand", "AUTOHAND_HOME"),
            ("~/.grok", "GROK_HOME"), ("~/.sarvam", "SARVAM_HOME"),
            ("~/.reasonix", "REASONIX_HOME")
        ]
        for (prefix, variable) in overrides where path == prefix || path.hasPrefix(prefix + "/") {
            if let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines),
               value.hasPrefix("/") {
                return URL(fileURLWithPath: value, isDirectory: true)
                    .appendingPathComponent(String(path.dropFirst(prefix.count)), isDirectory: true)
            }
        }
        return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
    }
}

/// 胶囊有工具身份，磁盘任务有目录身份；两个工具共用目录时仍能分别展示品牌。
struct RepoSkillAgentTarget: Identifiable, Sendable {
    let preset: RepoSkillTargetPreset
    let destinationID: String
    let applicationPath: String?

    var id: RepoSkillTargetPreset { preset }
}

/// 静态安装表参考 Vercel skills；只包含有用户级目录的工具，不把工作区专属路径写入用户主目录。
enum RepoSkillAgentCatalog {
    static let entries: [RepoSkillTargetPreset: RepoSkillAgent] = [
        .agents: .init("", "~/.agents/skills"),
        .claudeCode: .init("Claude Code", "~/.claude/skills", command: "claude", application: "Claude", logo: "claudecode"),
        .codex: .init("Codex", "~/.agents/skills", configuration: "~/.codex", command: "codex", application: "Codex", logo: "codex"),
        .cursor: .init("Cursor", "~/.cursor/skills", command: "cursor", application: "Cursor", logo: "cursor"),
        .githubCopilot: .init("GitHub Copilot", "~/.copilot/skills", command: "copilot",
                             extensions: ["github.copilot-"], logo: "githubcopilot"),
        .geminiCLI: .init("Gemini CLI", "~/.gemini/skills", command: "gemini", logo: "geminicli"),
        .windsurf: .init("Windsurf", "~/.codeium/windsurf/skills", application: "Windsurf", logo: "windsurf"),
        .cline: .init("Cline", "~/.agents/skills", configuration: "~/.cline", command: "cline",
                     extensions: ["saoudrizwan.claude-dev-"], logo: "cline"),
        .rooCode: .init("Roo Code", "~/.roo/skills", extensions: ["rooveterinaryinc.roo-cline-"], logo: "roocode"),
        .kiloCode: .init("Kilo Code", "~/.kilo/skills", command: "kilo",
                        extensions: ["kilocode.kilo-code-"], logo: "kilocode"),
        .continueAgent: .init("Continue", "~/.continue/skills", command: "cn", extensions: ["continue.continue-"], logo: "continue"),
        .openCode: .init("OpenCode", "~/.config/opencode/skills", command: "opencode", application: "OpenCode", logo: "opencode"),
        .amp: .init("Amp", "~/.config/agents/skills", configuration: "~/.config/amp", command: "amp", logo: "amp"),
        .goose: .init("Goose", "~/.config/goose/skills", command: "goose", application: "Goose", logo: "goose"),
        .droid: .init("Droid", "~/.factory/skills", command: "droid", logo: "factory"),
        .trae: .init("Trae", "~/.trae/skills", application: "Trae", logo: "trae"),
        .traeCN: .init("Trae CN", "~/.trae-cn/skills", application: "Trae CN", logo: "trae"),
        .qwenCode: .init("Qwen Code", "~/.qwen/skills", command: "qwen", logo: "qwen"),
        .kimiCode: .init("Kimi Code CLI", "~/.agents/skills", configuration: "~/.kimi", command: "kimi", logo: "kimi"),
        .iFlow: .init("iFlow CLI", "~/.iflow/skills", command: "iflow", logo: "iflow"),
        .pi: .init("Pi", "~/.agents/skills", configuration: "~/.pi/agent", command: "pi", logo: "pi"),
        .augment: .init("Augment", "~/.augment/skills", command: "auggie",
                       extensions: ["augment.vscode-augment-"], logo: "augment"),
        .antigravity: .init("Antigravity", "~/.gemini/config/skills", configuration: "~/.gemini/antigravity",
                           application: "Antigravity", logo: "antigravity"),
        .antigravityCLI: .init("Antigravity CLI", "~/.gemini/config/skills", configuration: "~/.gemini/antigravity-cli",
                              command: "agy", logo: "antigravity"),
        .junie: .init("Junie", "~/.junie/skills", command: "junie", logo: "junie"),
        .kiro: .init("Kiro CLI", "~/.kiro/skills", command: "kiro-cli", application: "Kiro", logo: "kiro"),
        .qoder: .init("Qoder", "~/.qoder/skills", command: "qodercli", application: "Qoder", logo: "qoder"),
        .qoderCN: .init("Qoder CN", "~/.qoder-cn/skills", application: "Qoder CN", logo: "qoder"),
        .codeBuddy: .init("CodeBuddy", "~/.codebuddy/skills", command: "codebuddy",
                         application: "CodeBuddy", extensions: ["tencent-cloud.coding-copilot-"], logo: "codebuddy"),
        .lingma: .init("Lingma", "~/.lingma/skills", extensions: ["alibaba-cloud.tongyi-lingma-"], logo: "lingma"),
        .warp: .init("Warp", "~/.agents/skills", configuration: "~/.warp", application: "Warp", logo: "warp"),
        .zed: .init("Zed", "~/.agents/skills", configuration: "~/.config/zed", command: "zed", application: "Zed", logo: "zed"),
        .mistralVibe: .init("Mistral Vibe", "~/.vibe/skills", command: "vibe", logo: "mistral"),
        .openHands: .init("OpenHands", "~/.openhands/skills", command: "openhands", logo: "openhands"),
        .openClaw: .init("OpenClaw", "~/.openclaw/skills", command: "openclaw", logo: "openclaw"),
        .miniMax: .init("MiniMax Code", "~/.minimax/skills", command: "mmc", logo: "minimax"),
        .grok: .init("Grok Build", "~/.grok/skills", command: "grok", logo: "grok"),
        .hermes: .init("Hermes Agent", "~/.hermes/skills", command: "hermes", logo: "hermesagent"),
        .cortex: .init("Cortex Code", "~/.snowflake/cortex/skills", command: "cortex", logo: "snowflake"),
        .crush: .init("Crush", "~/.config/crush/skills", command: "crush", logo: "crush"),
        .devin: .init("Devin for Terminal", "~/.config/devin/skills", command: "devin", logo: "devin"),
        .deepAgents: .init("Deep Agents", "~/.deepagents/agent/skills", configuration: "~/.deepagents", command: "deepagents", logo: "langchain"),
        .firebender: .init("Firebender", "~/.firebender/skills", logo: "firebender"),
        .mux: .init("Mux", "~/.mux/skills", command: "mux", application: "Mux", logo: "mux"),
        .ona: .init("Ona", "~/.ona/skills", command: "ona", logo: "ona"),
        .commandCode: .init("Command Code", "~/.commandcode/skills", logo: "commandcode"),
        .tabnine: .init("Tabnine CLI", "~/.tabnine/agent/skills", configuration: "~/.tabnine", command: "tabnine", logo: "tabnine"),
        .aiderDesk: .init("AiderDesk", "~/.aider-desk/skills", application: "AiderDesk"),
        .astrBot: .init("AstrBot", "~/.astrbot/data/skills", configuration: "~/.astrbot"),
        .autohand: .init("Autohand Code CLI", "~/.autohand/skills", command: "autohand", logo: "autohand"),
        .bob: .init("IBM Bob", "~/.bob/skills", command: "bob", logo: "ibm"),
        .codeArts: .init("CodeArts Agent", "~/.codeartsdoer/skills", command: "codearts"),
        .codeMaker: .init("Codemaker", "~/.codemaker/skills", command: "codemaker"),
        .codeStudio: .init("Code Studio", "~/.codestudio/skills", application: "Code Studio"),
        .dexto: .init("Dexto", "~/.agents/skills", configuration: "~/.dexto", command: "dexto"),
        .forgeCode: .init("ForgeCode", "~/.forge/skills", command: "forge"),
        .fx: .init("fx", "~/.agents/skills", configuration: "~/.fx", command: "fx"),
        .inference: .init("inference.sh", "~/.inferencesh/skills", command: "infsh"),
        .jazz: .init("Jazz", "~/.jazz/skills", command: "jazz"),
        .kimchi: .init("Kimchi", "~/.config/kimchi/harness/skills", configuration: "~/.config/kimchi", command: "kimchi"),
        .kode: .init("Kode", "~/.kode/skills", command: "kode"),
        .loaf: .init("Loaf", "~/.agents/skills", configuration: "~/.loaf", command: "loaf"),
        .mcpJam: .init("MCPJam", "~/.mcpjam/skills", command: "mcpjam"),
        .moxby: .init("Moxby", "~/.moxby/skills", command: "moxby", application: "Moxby"),
        .posit: .init("Posit Assistant", "~/.posit/assistant/skills", configuration: "~/.posit", logo: "posit"),
        .replit: .init("Replit", "~/.config/agents/skills", configuration: "~/.config/replit", application: "Replit", logo: "replit"),
        .reasonix: .init("Reasonix", "~/.reasonix/skills", command: "reasonix"),
        .rovoDev: .init("Rovo Dev", "~/.rovodev/skills", logo: "rovodev"),
        .sarvam: .init("Sarvam Code", "~/.agents/skills", configuration: "~/.sarvam", command: "sarvam"),
        .terramind: .init("Terramind", "~/.terramind/skills", command: "terramind"),
        .tinycloud: .init("Tinycloud", "~/.tinycloud/skills", command: "tinycloud"),
        .zcode: .init("ZCode", "~/.zcode/skills", application: "ZCode"),
        .zencoder: .init("Zencoder", "~/.zencoder/skills", extensions: ["zencoderai.zencoder-"], logo: "zencoder"),
        .zenflow: .init("Zenflow", "~/.zencoder/skills", application: "Zenflow", logo: "zencoder"),
        .neovate: .init("Neovate", "~/.neovate/skills", command: "neovate"),
        .pochi: .init("Pochi", "~/.pochi/skills", command: "pochi", extensions: ["tabbyml.pochi-"]),
        .adal: .init("AdaL", "~/.adal/skills", command: "adal")
    ]

    /// 目录、应用包和扩展均在后台只读枚举；不存在的工具不占面板空间，仍可经“更多工具”手动加入。
    @concurrent nonisolated static func detect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationDirectories: [URL]? = nil,
        executableDirectories: [URL]? = nil
    ) async -> [RepoSkillAgentTarget] {
        let fileManager = FileManager.default
        let applications = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications")
        ]
        let binaries = executableDirectories?.map(\.path)
            ?? ((environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
                "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path
            ])
        let extensionRoots = [".vscode/extensions", ".vscode-insiders/extensions", ".cursor/extensions",
                              ".windsurf/extensions", ".vscode-oss/extensions"]
        let extensionNames = extensionRoots.flatMap {
            (try? fileManager.contentsOfDirectory(atPath: home.appendingPathComponent($0).path)) ?? []
        }.map { $0.lowercased() }
        return RepoSkillTargetPreset.allCases.compactMap { preset in
            let agent = preset.agent
            let application = agent.application.flatMap { name in
                applications.map { $0.appendingPathComponent(name + ".app").path }
                    .first { fileManager.fileExists(atPath: $0) }
            }
            let configuration = agent.configurationURL(home: home, environment: environment)
            let contents = (try? fileManager.contentsOfDirectory(atPath: configuration.path)) ?? []
            let hasConfiguration = contents.contains { $0 != "skills" && !$0.hasPrefix(".") }
            let hasBinary = agent.command.map { command in
                binaries.contains { fileManager.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(command).path) }
            } ?? false
            let hasExtension = agent.extensions.contains { prefix in extensionNames.contains { $0.hasPrefix(prefix) } }
            guard preset == .agents || application != nil || hasConfiguration || hasBinary || hasExtension else { return nil }
            let destination = RepoSkillDestination(preset: preset, url: agent.directoryURL(home: home, environment: environment))
            return RepoSkillAgentTarget(preset: preset, destinationID: destination.id, applicationPath: application)
        }
    }
}
