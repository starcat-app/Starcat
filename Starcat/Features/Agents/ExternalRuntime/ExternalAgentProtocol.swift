//
//  ExternalAgentProtocol.swift
//  Starcat
//
//  外部 Agent 进程与 Provider 协议 adapter 共用的窄接口。
//
//  Host 只理解逐行 JSON-RPC、进程生命周期和统一事件；Codex / DeepSeek 的方法名、
//  握手状态机与事件结构全部留在 adapter 中，避免协议差异渗入 Workspace。
//

import Foundation

/// 外部 Runtime 在当前 Run 内访问 Starcat MCP 的一次性连接信息。
/// Token 只通过子进程环境传递，不进入 Cordis 文件、UserDefaults 或日志。
struct ExternalAgentMCPConnection: Sendable {
    let endpointURL: URL
    let bearerToken: String
}

/// 临时 MCP Server 的租约。Runtime 无论正常、失败或取消都必须调用 `shutdown`，
/// 防止 Agent Run 结束后仍有端口和本地数据入口残留。
struct ExternalAgentMCPLease: Sendable {
    let connection: ExternalAgentMCPConnection
    let shutdown: @Sendable () async -> Void
}

struct ExternalAgentRunRequest: Sendable {
    let runID: UUID
    let prompt: String
    let modelName: String?
    let reasoningEffort: String?
    let workingDirectory: URL
    /// 只有已经过 Agent definition allowlist 与只读权限过滤的工具才会进入 Provider。
    let tools: [AgentToolDefinition]
    /// 仅外部 Runtime 自带 MCP client 使用；Codex dynamic tools 等路径保持 nil。
    let mcpConnection: ExternalAgentMCPConnection?

    init(
        runID: UUID,
        prompt: String,
        modelName: String?,
        reasoningEffort: String?,
        workingDirectory: URL,
        tools: [AgentToolDefinition],
        mcpConnection: ExternalAgentMCPConnection? = nil
    ) {
        self.runID = runID
        self.prompt = prompt
        self.modelName = modelName
        self.reasoningEffort = reasoningEffort
        self.workingDirectory = workingDirectory
        self.tools = tools
        self.mcpConnection = mcpConnection
    }
}

struct ExternalAgentProcessConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL
}

enum ExternalAgentProtocolEvent: Equatable, Sendable {
    case trace(ExternalAgentTraceEvent)
    case assistantDelta(String)
    case reasoningDelta(String)
    case assistantMessage(String, usage: AgentUsage?)
    case toolCall(id: String, name: String, input: AgentJSONValue, rawInput: String?)
    case toolResult(id: String, name: String, output: AgentJSONValue, isError: Bool)
    case artifactMarkdown(String, toolCallID: String)
    case usage(AgentUsage)
    /// 由 Host 从子进程启动到首个产品事件实测，不依赖 Provider 自报。
    case firstOutputLatency(Int)
    case completed
    case cancelled
    case failed(String)
}

/// Provider adapter 输出的 Runtime 原生事件。`sequence` 与 `runID` 由 projector 统一分配，
/// adapter 只负责保留 Provider 的事件身份、类型和安全可展示字段。
struct ExternalAgentTraceEvent: Equatable, Sendable {
    let id: String
    let parentID: String?
    let kind: AgentTraceKind
    let status: AgentTraceStatus
    let title: String
    let summary: String?
    let details: [AgentTraceDetail]
    let attempt: Int?
    let durationMilliseconds: Int?
    let usage: AgentUsage?
    let startedAt: Date?
    let completedAt: Date?

    init(
        id: String,
        parentID: String? = nil,
        kind: AgentTraceKind,
        status: AgentTraceStatus,
        title: String,
        summary: String? = nil,
        details: [AgentTraceDetail] = [],
        attempt: Int? = nil,
        durationMilliseconds: Int? = nil,
        usage: AgentUsage? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.status = status
        self.title = title
        self.summary = summary
        self.details = details
        self.attempt = attempt
        self.durationMilliseconds = durationMilliseconds
        self.usage = usage
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// Provider 请求 Starcat 宿主执行一次动态工具调用。
///
/// `requestID` 保留 JSON-RPC 原始类型，Codex 当前通常使用数字，但 Host 不应假设
/// Provider 的 request id 永远是 Int，否则协议升级后无法把结果准确回写给同一请求。
struct ExternalAgentToolRequest: Sendable {
    let requestID: AgentJSONValue
    let callID: String
    let name: String
    let input: AgentJSONValue
    let rawInput: String?
}

/// Starcat 工具执行器返回给外部 Provider 的有界结果。
struct ExternalAgentToolExecutionResult: Sendable {
    let output: AgentJSONValue
    let modelText: String
    let isError: Bool
    let artifactMarkdown: String?
}

struct ExternalAgentProtocolOutput: Sendable {
    var outboundFrames: [AgentJSONValue] = []
    var events: [ExternalAgentProtocolEvent] = []
    var toolRequests: [ExternalAgentToolRequest] = []
    var isTerminal = false
}

/// 把 Provider 的未知或扩展事件降级为可展示的结构化数据，同时阻断凭据、环境变量、
/// system prompt 与工具 schema 进入普通产品 UI。它保留的是事件业务数据的有界投影，
/// 不是 JSON-RPC 原始帧；adapter 应优先显式映射已知字段，仅在协议扩展时使用该兜底。
enum ExternalAgentTracePayload {
    private static let redactedKeyFragments = [
        "authorization", "apikey", "accesstoken", "refreshtoken", "bearer",
        "password", "secret", "credential", "cookie", "environment", "system",
    ]
    private static let redactedExactKeys: Set<String> = [
        "env", "token", "tools", "inputschema",
    ]
    private static let maxDepth = 6
    private static let maxObjectFields = 40
    private static let maxArrayItems = 50
    private static let maxStringCharacters = 4_000

    static func detail(label: String, value: AgentJSONValue) -> AgentTraceDetail? {
        guard let json = try? sanitized(value).jsonString() else { return nil }
        return AgentTraceDetail(label: label, value: json, format: .json)
    }

    static func sanitized(_ value: AgentJSONValue, depth: Int = 0) -> AgentJSONValue {
        guard depth < maxDepth else { return .string("…") }
        switch value {
        case .object(let object):
            let keys = object.keys.sorted()
            var result: [String: AgentJSONValue] = [:]
            for key in keys.prefix(maxObjectFields) {
                if isSensitive(key) {
                    result[key] = .string("<redacted>")
                } else {
                    result[key] = sanitized(object[key] ?? .null, depth: depth + 1)
                }
            }
            if keys.count > maxObjectFields { result["…"] = .string("truncated") }
            return .object(result)
        case .array(let values):
            var result = values.prefix(maxArrayItems).map { sanitized($0, depth: depth + 1) }
            if values.count > maxArrayItems { result.append(.string("…")) }
            return .array(Array(result))
        case .string(let text):
            guard text.count > maxStringCharacters else { return value }
            return .string(String(text.prefix(maxStringCharacters)) + "…")
        case .number, .bool, .null:
            return value
        }
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return redactedExactKeys.contains(normalized)
            || redactedKeyFragments.contains { normalized.contains($0) }
    }
}

/// 一次 run 对应一个可变协议状态机；Host actor 保证所有调用串行发生。
protocol ExternalAgentProtocolDriver: AnyObject, Sendable {
    var backend: AgentRuntimeBackend { get }
    var capabilities: AgentRuntimeCapabilities { get }
    var processConfiguration: ExternalAgentProcessConfiguration { get }

    func initialFrames() throws -> [AgentJSONValue]
    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput
    func toolResponseFrame(
        for request: ExternalAgentToolRequest,
        result: ExternalAgentToolExecutionResult
    ) -> AgentJSONValue?
    func cancellationFrame() -> AgentJSONValue?
    func shutdownFrame() -> AgentJSONValue?
}

extension ExternalAgentProtocolDriver {
    /// 不支持双向动态工具的 Provider 明确返回 nil；Host 收到工具请求时会终止而不是
    /// 伪造成功结果。DeepSeek Harness 当前走这条兼容路径。
    func toolResponseFrame(
        for request: ExternalAgentToolRequest,
        result: ExternalAgentToolExecutionResult
    ) -> AgentJSONValue? { nil }
}

protocol ExternalAgentProtocolAdapter: Sendable {
    var backend: AgentRuntimeBackend { get }
    var capabilities: AgentRuntimeCapabilities { get }
    func makeDriver(request: ExternalAgentRunRequest) throws -> any ExternalAgentProtocolDriver
}

enum ExternalAgentRuntimeError: Error, LocalizedError, Equatable, Sendable {
    case directOnly
    case executableNotFound(String)
    case executableNotRunnable(String)
    case unsupportedArchitecture(String)
    case missingConfiguration(String)
    case invalidFrame
    case protocolError(String)
    case processExited(Int32, String?)
    case firstOutputTimedOut(String?)
    case protocolActivityTimedOut(String?)
    case processClosedBeforeCompletion(String?)

    var errorDescription: String? {
        switch self {
        case .directOnly:
            return "External Agent Runtime is available only in the Direct build."
        case .executableNotFound(let name):
            return "External Agent executable was not found: \(name)."
        case .executableNotRunnable(let path):
            return "External Agent executable is not runnable: \(path)."
        case .unsupportedArchitecture(let architecture):
            return "External Agent Runtime does not support this architecture: \(architecture)."
        case .missingConfiguration(let key):
            return "External Agent Runtime configuration is missing: \(key)."
        case .invalidFrame:
            return "External Agent Runtime returned malformed JSON-RPC."
        case .protocolError(let message):
            return message
        case .processExited(let status, let diagnostic):
            let message = "External Agent Runtime exited with status \(status)."
            guard let diagnostic, !diagnostic.isEmpty else { return message }
            return "\(message) \(diagnostic)"
        case .firstOutputTimedOut(let diagnostic):
            let message = "External Agent Runtime did not produce an assistant or tool event before startup timed out."
            guard let diagnostic, !diagnostic.isEmpty else { return message }
            return "\(message) \(diagnostic)"
        case .protocolActivityTimedOut(let diagnostic):
            let message = "External Agent Runtime stopped producing protocol activity before the turn completed."
            guard let diagnostic, !diagnostic.isEmpty else { return message }
            return "\(message) \(diagnostic)"
        case .processClosedBeforeCompletion(let diagnostic):
            let message = "External Agent Runtime closed before the turn completed."
            guard let diagnostic, !diagnostic.isEmpty else { return message }
            return "\(message) \(diagnostic)"
        }
    }
}

/// 只返回经过 `isExecutableFile` 验证的绝对路径；不执行 shell，也不在线安装 Runtime。
struct ExternalAgentExecutableResolver: Sendable {
    let environment: [String: String]
    let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func resolve(executableName: String, explicitPath: String?) throws -> URL {
        let fileManager = FileManager.default
        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: explicitPath).standardizedFileURL
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw ExternalAgentRuntimeError.executableNotRunnable(url.path)
            }
            return url
        }

        let pathCandidates = environment["PATH"]?.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(executableName)
        } ?? []
        let commonCandidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(executableName)"),
            URL(fileURLWithPath: "/usr/local/bin/\(executableName)"),
            homeDirectory.appendingPathComponent(".local/bin/\(executableName)"),
            homeDirectory.appendingPathComponent(".npm-global/bin/\(executableName)"),
            homeDirectory.appendingPathComponent(".bun/bin/\(executableName)"),
        ]
        var visited = Set<String>()
        for candidate in pathCandidates + commonCandidates {
            let url = candidate.standardizedFileURL
            guard visited.insert(url.path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        throw ExternalAgentRuntimeError.executableNotFound(executableName)
    }
}

enum ExternalAgentProcessEnvironment {
    /// 外部 Runtime 不应继承 Starcat 的全部环境。这里只保留启动、locale、登录态目录和
    /// POC Provider 所需的显式凭据变量；这些值从不写日志或 UserDefaults。
    static func filtered(
        source: [String: String] = ProcessInfo.processInfo.environment,
        allowedCredentialKeys: Set<String> = [],
        additional: [String: String] = [:]
    ) -> [String: String] {
        let baseAllowlist: Set<String> = [
            "HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL",
            "SSH_AUTH_SOCK", "CODEX_HOME"
        ]
        let allowlist = baseAllowlist.union(allowedCredentialKeys)
        var result = source.filter { allowlist.contains($0.key) }
        for (key, value) in additional where !value.isEmpty {
            result[key] = value
        }
        return result
    }
}

extension AgentJSONValue {
    var externalObject: [String: AgentJSONValue]? { objectValue }

    var externalArray: [AgentJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var externalBool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var externalNumber: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    subscript(external key: String) -> AgentJSONValue? {
        objectValue?[key]
    }

    /// Provider 的安全展示通常只允许保留业务元数据；例如 compaction summary 必须排除
    /// rawOutput 与 system/tool 配置，同时继续把剩余字段作为合法 JSON 交给结构化 renderer。
    func removingExternalKeys(_ keys: Set<String>) -> AgentJSONValue {
        guard case .object(let object) = self else { return self }
        return .object(object.filter { !keys.contains($0.key) })
    }

    static func jsonRPCRequest(id: Int, method: String, params: AgentJSONValue? = nil) -> AgentJSONValue {
        var object: [String: AgentJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func jsonRPCNotification(method: String, params: AgentJSONValue? = nil) -> AgentJSONValue {
        var object: [String: AgentJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }
}
