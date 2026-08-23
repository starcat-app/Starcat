//
//  ExternalAgentRuntimePOCPreferences.swift
//  Starcat
//
//  Direct Debug 构建的隐藏 POC 配置入口。
//
//  可执行文件路径可以用 Xcode launch arguments / defaults 注入；Provider/Model 由
//  工作台选择。API Key 来自 Starcat 已加密保存的 AI Provider，禁止写入 UserDefaults。
//  Release 构建始终返回 builtinLoop。
//

import Foundation

enum ExternalAgentRuntimePOCPreferences {
    static let backendKey = "DebugExternalAgentRuntimeBackend"
    static let codexExecutablePathKey = "DebugCodexExecutablePath"
    static let codexProviderKey = "DebugCodexProvider"
    static let codexModelKey = "DebugCodexModel"
    static let codexReasoningEffortKey = "DebugCodexReasoningEffort"
    static let deepSeekExecutablePathKey = "DebugDeepSeekHarnessExecutablePath"
    static let deepSeekCordisConfigPathKey = "DebugDeepSeekHarnessCordisConfigPath"
    static let deepSeekProviderKey = "DebugDeepSeekHarnessProvider"
    static let deepSeekModelKey = "DebugDeepSeekHarnessModel"
    static let deepSeekReasoningEffortKey = "DebugDeepSeekHarnessReasoningEffort"

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

    @MainActor
    static func makeAdapter(
        backend: AgentRuntimeBackend,
        resolver: ExternalAgentExecutableResolver = ExternalAgentExecutableResolver(),
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: AppSettings? = nil,
        keychain: any KeychainManaging = KeychainManager.shared
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
                providerID: defaults.string(forKey: codexProviderKey),
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
            let routeSelection = settings.flatMap { settings in
                DeepSeekRuntimeProviderCatalog.resolvedSelection(
                    settings: settings,
                    preferredProviderID: defaults.string(forKey: deepSeekProviderKey),
                    preferredModelName: defaults.string(forKey: deepSeekModelKey),
                    preferredReasoningEffort: defaults.string(forKey: deepSeekReasoningEffortKey)
                )
            }
            if settings != nil, routeSelection == nil {
                throw ExternalAgentRuntimeError.missingConfiguration("Verified AI Provider for DeepSeek Harness")
            }
            return try DeepSeekHarnessAdapter(
                executableURL: executable,
                provider: routeSelection == nil
                    ? (defaults.string(forKey: deepSeekProviderKey) ?? DeepSeekHarnessRuntime.defaultProvider)
                    : DeepSeekRuntimeSelection.providerRoute,
                modelOverride: routeSelection?.model.name
                    ?? defaults.string(forKey: deepSeekModelKey)
                    ?? DeepSeekHarnessRuntime.defaultModel,
                cordisConfigURL: URL(fileURLWithPath: configPath),
                environment: ExternalAgentProcessEnvironment.filtered(
                    source: deepSeekEnvironment(
                        source: environment,
                        settings: settings,
                        keychain: keychain,
                        preferredProviderID: routeSelection?.provider.id
                    ),
                    allowedCredentialKeys: [
                        "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "OPENAI_API_KEY", "OPENAI_BASE_URL",
                        DeepSeekRuntimeSelection.credentialEnvironmentKey,
                    ]
                ),
                routeConfiguration: routeSelection
            )
        }
    }

    /// 为外部 DeepSeek Runtime 生成最小凭据环境。
    ///
    /// shell 显式注入的环境变量优先；正常从 Finder 启动时环境里通常没有 API Key，
    /// 此时复用 Starcat 设置页已加密保存的 DeepSeek Provider。只注入当前 Runtime
    /// 必需的 Key/Base URL，不能把完整 App 环境交给可执行工具的外部进程。
    @MainActor
    static func deepSeekEnvironment(
        source: [String: String],
        settings: AppSettings?,
        keychain: any KeychainManaging,
        preferredProviderID: String? = nil
    ) -> [String: String] {
        guard let settings,
              let profile = preferredRuntimeProfile(
                settings: settings,
                preferredProviderID: preferredProviderID
              )
        else { return source }
        var environment = source
        if environment[DeepSeekRuntimeSelection.credentialEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            let storedKey = (try? keychain.loadAIKey(forProvider: profile.id))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let credential = (storedKey?.isEmpty == false ? storedKey : nil)
                ?? profile.provider.fallbackAPIKey
            if !credential.isEmpty {
                environment[DeepSeekRuntimeSelection.credentialEnvironmentKey] = credential
            }
        }
        // 保留 0.1.1rc1 官方 DeepSeek route 的环境变量，兼容手工集成测试与旧配置；
        // 产品化的多 Provider 路由只读取上面的 STARCAT_RUNTIME_API_KEY。
        if profile.provider == .deepSeek,
           environment["DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let credential = environment[DeepSeekRuntimeSelection.credentialEnvironmentKey] {
            environment["DEEPSEEK_API_KEY"] = credential
            let baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !baseURL.isEmpty { environment["DEEPSEEK_BASE_URL"] = baseURL }
        }
        return environment
    }

    @MainActor
    private static func preferredRuntimeProfile(
        settings: AppSettings,
        preferredProviderID: String?
    ) -> AIProviderProfile? {
        let profiles = settings.aiProviderProfiles.filter(\.isVerifiedConfiguration)
        return profiles.first(where: { $0.id == preferredProviderID })
            ?? profiles.first(where: { $0.id == settings.aiChatTask.providerID })
            ?? profiles.first
    }

    static func makeCodexModelCatalogClient(
        providerID: String? = nil,
        resolver: ExternalAgentExecutableResolver = ExternalAgentExecutableResolver(),
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CodexModelCatalogClient {
        CodexModelCatalogClient(
            executableURL: try resolveCodexExecutable(resolver: resolver, defaults: defaults),
            providerID: providerID,
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
