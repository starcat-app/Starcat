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

struct ExternalAgentRunRequest: Sendable {
    let runID: UUID
    let prompt: String
    let modelName: String?
    let workingDirectory: URL
}

struct ExternalAgentProcessConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL
}

enum ExternalAgentProtocolEvent: Equatable, Sendable {
    case assistantDelta(String)
    case reasoningDelta(String)
    case assistantMessage(String, usage: AgentUsage?)
    case toolCall(id: String, name: String, input: AgentJSONValue, rawInput: String?)
    case toolResult(id: String, name: String, output: AgentJSONValue, isError: Bool)
    case usage(AgentUsage)
    case completed
    case cancelled
    case failed(String)
}

struct ExternalAgentProtocolOutput: Sendable {
    var outboundFrames: [AgentJSONValue] = []
    var events: [ExternalAgentProtocolEvent] = []
    var isTerminal = false
}

/// 一次 run 对应一个可变协议状态机；Host actor 保证所有调用串行发生。
protocol ExternalAgentProtocolDriver: AnyObject, Sendable {
    var backend: AgentRuntimeBackend { get }
    var capabilities: AgentRuntimeCapabilities { get }
    var processConfiguration: ExternalAgentProcessConfiguration { get }

    func initialFrames() throws -> [AgentJSONValue]
    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput
    func cancellationFrame() -> AgentJSONValue?
    func shutdownFrame() -> AgentJSONValue?
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
    case processExited(Int32)
    case processClosedBeforeCompletion

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
        case .processExited(let status):
            return "External Agent Runtime exited with status \(status)."
        case .processClosedBeforeCompletion:
            return "External Agent Runtime closed before the turn completed."
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
