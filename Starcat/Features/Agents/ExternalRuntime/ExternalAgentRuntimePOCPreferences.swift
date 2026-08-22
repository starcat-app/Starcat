//
//  ExternalAgentRuntimePOCPreferences.swift
//  Starcat
//
//  Direct Debug 构建的隐藏 POC 配置入口。
//
//  路径、provider 和 model 可以用 Xcode launch arguments / defaults 注入；API Key
//  只允许来自进程环境，禁止写入 UserDefaults。Release 构建始终返回 builtinLoop。
//

import Foundation

enum ExternalAgentRuntimePOCPreferences {
    static let backendKey = "DebugExternalAgentRuntimeBackend"
    static let codexExecutablePathKey = "DebugCodexExecutablePath"
    static let codexModelKey = "DebugCodexModel"
    static let codexReasoningEffortKey = "DebugCodexReasoningEffort"
    static let deepSeekExecutablePathKey = "DebugDeepSeekHarnessExecutablePath"
    static let deepSeekCordisConfigPathKey = "DebugDeepSeekHarnessCordisConfigPath"
    static let deepSeekProviderKey = "DebugDeepSeekHarnessProvider"
    static let deepSeekModelKey = "DebugDeepSeekHarnessModel"

    static var selectedBackend: AgentRuntimeBackend {
        #if DEBUG
        let rawValue = UserDefaults.standard.string(forKey: backendKey)
        return AgentRuntimeBackend(rawValue: rawValue ?? "") ?? .builtinLoop
        #else
        return .builtinLoop
        #endif
    }

    static func isExternalPOCEnabled(distributionGate: DistributionGate = DistributionGate()) -> Bool {
        #if DEBUG
        return selectedBackend != .builtinLoop
            && distributionGate.isAvailable(.externalAgentRuntime)
        #else
        return false
        #endif
    }

    static func makeAdapter(
        backend: AgentRuntimeBackend,
        resolver: ExternalAgentExecutableResolver = ExternalAgentExecutableResolver(),
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any ExternalAgentProtocolAdapter {
        switch backend {
        case .builtinLoop:
            throw ExternalAgentRuntimeError.missingConfiguration("External backend")
        case .codexAppServer:
            return CodexAppServerAdapter(
                executableURL: try resolveCodexExecutable(
                    resolver: resolver,
                    defaults: defaults
                ),
                // Codex 使用本机 CODEX_HOME 登录态。禁止把 Starcat 进程中的 API Key
                // 交给可调用命令工具的外部 Runtime，避免 prompt 注入读取环境凭据。
                environment: ExternalAgentProcessEnvironment.filtered(source: environment)
            )
        case .deepSeekHarness:
            let executable = try resolver.resolve(
                executableName: "dsh-jsonrpc-agent-pkg-macos-arm64",
                explicitPath: defaults.string(forKey: deepSeekExecutablePathKey)
            )
            guard let configPath = defaults.string(forKey: deepSeekCordisConfigPathKey),
                  !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ExternalAgentRuntimeError.missingConfiguration(deepSeekCordisConfigPathKey)
            }
            return try DeepSeekHarnessAdapter(
                executableURL: executable,
                provider: defaults.string(forKey: deepSeekProviderKey) ?? "deepseek-official",
                modelOverride: defaults.string(forKey: deepSeekModelKey),
                cordisConfigURL: URL(fileURLWithPath: configPath),
                environment: ExternalAgentProcessEnvironment.filtered(
                    source: environment,
                    allowedCredentialKeys: [
                        "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "OPENAI_API_KEY", "OPENAI_BASE_URL"
                    ]
                )
            )
        }
    }

    static func makeCodexModelCatalogClient(
        resolver: ExternalAgentExecutableResolver = ExternalAgentExecutableResolver(),
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CodexModelCatalogClient {
        CodexModelCatalogClient(
            executableURL: try resolveCodexExecutable(resolver: resolver, defaults: defaults),
            // 模型目录与正式 turn 使用相同的本机 Codex 登录态和凭据过滤边界。
            environment: ExternalAgentProcessEnvironment.filtered(source: environment)
        )
    }

    private static func resolveCodexExecutable(
        resolver: ExternalAgentExecutableResolver,
        defaults: UserDefaults
    ) throws -> URL {
        try resolver.resolve(
            executableName: "codex",
            explicitPath: defaults.string(forKey: codexExecutablePathKey)
        )
    }
}
