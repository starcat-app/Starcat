//
//  AgentRuntimeProviderCatalog.swift
//  Starcat
//
//  外部 Agent Runtime 的 Provider / Model 目录适配。
//
//  Codex 的可选 Provider 来自用户本机 `config.toml`；DeepSeek Harness 的 JSON-RPC
//  carrier 没有目录接口，因此复用 Starcat 设置页中已经验证的 OpenAI-compatible
//  Provider。这里仅生成非敏感能力快照，API Key 仍按 profile ID 从 Keychain 读取。
//

import Foundation

struct CodexProviderOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isActive: Bool
    /// Starcat 不把任意 Provider API Key 交给可运行命令的 Codex 子进程。
    let credentialEnvironmentKey: String?
    /// 只保留公开端点地址，用于识别必须先启动本机桥接服务的 Provider。
    let baseURL: URL?

    var isSelectable: Bool { credentialEnvironmentKey == nil }

    /// 远端服务交给 Codex 自己处理鉴权与重试；只有 loopback 端点需要 Starcat
    /// 预检，否则桥接进程未启动时 Codex 会进入多轮网络重试，看起来像界面卡死。
    var requiresEndpointProbe: Bool {
        guard let host = baseURL?.host?.lowercased() else { return false }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".localhost")
    }
}

struct CodexProviderEndpointProbe: Sendable {
    typealias Request = @Sendable (URLRequest) async throws -> Void

    private let timeoutInterval: TimeInterval
    private let request: Request?

    init(timeoutInterval: TimeInterval = 1, request: Request? = nil) {
        self.timeoutInterval = timeoutInterval
        self.request = request
    }

    /// 任意 HTTP 响应都说明本机桥接端口已在线；401/404 等协议响应应继续交给
    /// Codex 处理。这里只把连接拒绝、超时等传输错误判定为不可用。
    func isAvailable(_ provider: CodexProviderOption) async -> Bool {
        guard provider.requiresEndpointProbe, let baseURL = provider.baseURL else { return true }
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "HEAD"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = timeoutInterval
        do {
            if let request {
                try await request(urlRequest)
            } else {
                _ = try await URLSession.shared.data(for: urlRequest)
            }
            return true
        } catch {
            return false
        }
    }
}

struct CodexProviderCatalog: Equatable, Sendable {
    let providers: [CodexProviderOption]
    let activeProviderID: String

    /// Codex 没有独立的 provider/list。这里只读取它自己支持的配置文件语义：顶层
    /// `model_provider` 决定当前路由，`[model_providers.<id>]` 声明用户可切换路由。
    /// 解析器故意保持窄范围，避免把任意 TOML 内容或凭据带进 Starcat。
    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> CodexProviderCatalog {
        let home = environment["CODEX_HOME"].flatMap { value -> URL? in
            let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let configURL = home.appendingPathComponent("config.toml")
        let source = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        return parse(source)
    }

    static func parse(_ source: String) -> CodexProviderCatalog {
        var activeProviderID = "openai"
        var section: String?
        var declaredOrder: [String] = []
        var displayNames: [String: String] = [:]
        var credentialEnvironmentKeys: [String: String] = [:]
        var baseURLs: [String: URL] = [:]

        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                if let providerID = providerID(fromSection: section), !declaredOrder.contains(providerID) {
                    declaredOrder.append(providerID)
                }
                continue
            }
            guard let assignment = assignment(from: line) else { continue }
            if section == nil, assignment.key == "model_provider", let value = tomlString(assignment.value) {
                activeProviderID = value
            } else if let providerID = providerID(fromSection: section),
                      assignment.key == "name",
                      let value = tomlString(assignment.value) {
                displayNames[providerID] = value
            } else if let providerID = providerID(fromSection: section),
                      assignment.key == "env_key",
                      let value = tomlString(assignment.value) {
                credentialEnvironmentKeys[providerID] = value
            } else if let providerID = providerID(fromSection: section),
                      assignment.key == "base_url",
                      let value = tomlString(assignment.value),
                      let url = URL(string: value) {
                baseURLs[providerID] = url
            }
        }

        // `openai` 是 Codex 自带且可使用本机登录态的路由，即使用户当前激活了自定义
        // Provider，也必须保留一个无需把第三方 API Key 交给子进程的安全回退入口。
        var ids = [activeProviderID]
        if !ids.contains("openai") { ids.append("openai") }
        for id in declaredOrder where !ids.contains(id) { ids.append(id) }
        return CodexProviderCatalog(
            providers: ids.map { id in
                CodexProviderOption(
                    id: id,
                    displayName: displayNames[id] ?? defaultDisplayName(for: id),
                    isActive: id == activeProviderID,
                    credentialEnvironmentKey: credentialEnvironmentKeys[id],
                    baseURL: baseURLs[id]
                )
            },
            activeProviderID: activeProviderID
        )
    }

    func resolvedProviderID(preferredProviderID: String?) -> String {
        guard let preferredProviderID,
              providers.contains(where: { $0.id == preferredProviderID })
        else { return activeProviderID }
        return preferredProviderID
    }

    private static func providerID(fromSection section: String?) -> String? {
        guard let section, section.hasPrefix("model_providers.") else { return nil }
        let suffix = String(section.dropFirst("model_providers.".count))
        if let quoted = tomlString(suffix) { return quoted }
        // `model_providers.gateway.http_headers` 是子表，不是另一个 Provider。
        guard !suffix.isEmpty, !suffix.contains(".") else { return nil }
        return suffix
    }

    private static func assignment(from line: String) -> (key: String, value: String)? {
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : (key, value)
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if character == "\"" || character == "'" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func tomlString(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              let first = value.first,
              (first == "\"" || first == "'"),
              value.last == first
        else { return nil }
        return String(value.dropFirst().dropLast())
    }

    private static func defaultDisplayName(for id: String) -> String {
        switch id.lowercased() {
        case "openai": return "OpenAI"
        case "azure": return "Azure OpenAI"
        case "ollama": return "Ollama"
        case "lmstudio": return "LM Studio"
        default: return id
        }
    }
}

enum CodexRuntimeProcessArguments {
    /// Provider 是进程级配置；每个目录查询和每次 Run 都启动独立 App Server，因而可用
    /// CLI 的标准 `-c model_provider=...` 安全切换，不会污染用户的 config.toml。
    static func appServer(providerID: String?) -> [String] {
        var arguments = ["app-server", "--listen", "stdio://"]
        if let providerID, !providerID.isEmpty {
            let escaped = providerID.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            arguments.append(contentsOf: ["-c", "model_provider=\"\(escaped)\""])
        }
        return arguments
    }
}

struct DeepSeekRuntimeModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let contextWindow: Int
    let maxTokens: Int
    let supportedReasoningEfforts: [String]
}

struct DeepSeekRuntimeProviderOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let provider: AIServiceProvider
    let baseURL: String
    let models: [DeepSeekRuntimeModelOption]
}

struct DeepSeekRuntimeSelection: Equatable, Sendable {
    static let providerRoute = "starcat-provider"
    static let credentialEnvironmentKey = "STARCAT_RUNTIME_API_KEY"

    let provider: DeepSeekRuntimeProviderOption
    let model: DeepSeekRuntimeModelOption
    let reasoningEffort: String?
}

enum DeepSeekRuntimeProviderCatalog {
    static let selectableReasoningEfforts = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    private static let deepSeekV4ContextWindowTokens = 1_000_000
    private static let deepSeekV4ModelIDs: Set<String> = [
        "deepseek-v4-pro",
        "deepseek-v4-flash",
    ]

    @MainActor
    static func providers(settings: AppSettings) -> [DeepSeekRuntimeProviderOption] {
        settings.aiProviderProfiles.compactMap { profile in
            guard profile.isVerifiedConfiguration else { return nil }
            var models = profile.models.filter {
                $0.isEnabled && ($0.capability == .chat || $0.capability == .unknown)
            }
            let task = settings.aiChatTask
            let customName = task.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if task.providerID == profile.id,
               task.useCustomModel,
               !customName.isEmpty,
               !models.contains(where: { $0.name == customName }) {
                models.append(AIModelDescriptor(
                    providerID: profile.id,
                    name: customName,
                    capability: .chat,
                    isCustom: true,
                    parameters: settings.effectiveParameters(for: task)
                ))
            }
            guard !models.isEmpty else { return nil }
            return DeepSeekRuntimeProviderOption(
                id: profile.id,
                displayName: profile.displayName,
                provider: profile.provider,
                baseURL: profile.baseURL,
                models: models.map(modelOption)
            )
        }
    }

    @MainActor
    static func resolvedSelection(
        settings: AppSettings,
        preferredProviderID: String?,
        preferredModelName: String?,
        preferredReasoningEffort: String?
    ) -> DeepSeekRuntimeSelection? {
        let providers = providers(settings: settings)
        guard let provider = providers.first(where: { $0.id == preferredProviderID })
            ?? providers.first(where: { $0.id == settings.aiChatTask.providerID })
            ?? providers.first,
              let model = provider.models.first(where: { $0.name == preferredModelName })
                ?? provider.models.first(where: { $0.name == settings.aiChatTask.resolvedModelName })
                ?? provider.models.first
        else { return nil }
        let effort = preferredReasoningEffort.flatMap { preferred in
            model.supportedReasoningEfforts.contains(preferred) ? preferred : nil
        }
        return DeepSeekRuntimeSelection(provider: provider, model: model, reasoningEffort: effort)
    }

    private static func modelOption(_ descriptor: AIModelDescriptor) -> DeepSeekRuntimeModelOption {
        let parameters = descriptor.parameters ?? AIModelParameters.defaults(for: .chat)
        return DeepSeekRuntimeModelOption(
            id: descriptor.id,
            name: descriptor.name,
            contextWindow: resolvedContextWindow(descriptor: descriptor, parameters: parameters),
            maxTokens: parameters.maxCompletionTokens,
            supportedReasoningEfforts: supportsReasoning(modelName: descriptor.name)
                ? selectableReasoningEfforts
                : []
        )
    }

    /// DeepSeek V4 官方上下文为 1M。模型目录未保存参数时不能复用通用 32K 保守值，
    /// 否则 Harness 会把正常的长工具链误判为达到上下文边界；用户显式配置仍然优先。
    private static func resolvedContextWindow(
        descriptor: AIModelDescriptor,
        parameters: AIModelParameters
    ) -> Int {
        guard descriptor.parameters == nil else {
            return parameters.resolvedContextWindowTokens
        }
        let modelID = descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return deepSeekV4ModelIDs.contains(modelID)
            ? deepSeekV4ContextWindowTokens
            : parameters.resolvedContextWindowTokens
    }

    /// Starcat 的 `/models` 目录没有统一 reasoning capability 字段。只对名称中明确带有
    /// 推理语义的模型开放强度选择；宁可保留 Provider 默认，也不能向普通 chat 模型
    /// 发送其不认识的 `reasoning_effort`。
    private static func supportsReasoning(modelName: String) -> Bool {
        let name = modelName.lowercased()
        let markers = [
            "reason", "thinking", "deepseek-r1", "deepseek-v4", "qwen3", "gpt-5",
            "o1", "o3", "o4", "glm-4.5", "glm-4.6", "kimi-k2",
        ]
        return markers.contains { name.contains($0) }
    }
}
