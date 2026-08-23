//
//  CodexModelCatalog.swift
//  Starcat
//
//  通过 Codex App Server 的 `model/list` 动态读取当前安装版本可用的模型与推理强度。
//
//  模型目录必须来自用户实际安装并登录的 Codex，不能在 Starcat 中硬编码：Codex CLI
//  升级、账户权限和灰度发布都可能改变目录。目录查询复用 ExternalAgentRuntimeHost，
//  因而与正式 turn 共享 JSONL、超时、stderr 排空和 SIGPIPE 防护边界。
//

import Foundation

struct CodexReasoningEffortOption: Identifiable, Equatable, Sendable {
    let reasoningEffort: String
    let description: String?

    var id: String { reasoningEffort }
}

struct CodexModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let supportedReasoningEfforts: [CodexReasoningEffortOption]
    let defaultReasoningEffort: String?
    let isDefault: Bool
}

struct CodexModelSelection: Equatable, Sendable {
    let modelID: String
    let modelName: String
    let displayName: String
    let reasoningEffort: String?
}

struct CodexModelCatalog: Equatable, Sendable {
    let models: [CodexModelOption]

    static let empty = CodexModelCatalog(models: [])

    /// 用户上次选择可能已从新目录中移除。此时回到服务端默认模型及其默认 effort，
    /// 而不是把已失效的字符串继续传给 turn/start。
    func resolvedSelection(
        preferredModelID: String?,
        preferredReasoningEffort: String?
    ) -> CodexModelSelection? {
        guard let model = models.first(where: { $0.id == preferredModelID })
            ?? models.first(where: \.isDefault)
            ?? models.first
        else { return nil }

        let supportedEfforts = model.supportedReasoningEfforts.map(\.reasoningEffort)
        let effort: String?
        if let preferredReasoningEffort,
           supportedEfforts.contains(preferredReasoningEffort) {
            effort = preferredReasoningEffort
        } else if let defaultReasoningEffort = model.defaultReasoningEffort,
                  supportedEfforts.contains(defaultReasoningEffort) {
            effort = defaultReasoningEffort
        } else {
            effort = supportedEfforts.first
        }
        return CodexModelSelection(
            modelID: model.id,
            modelName: model.model,
            displayName: model.displayName,
            reasoningEffort: effort
        )
    }

    static func parsePage(
        from result: AgentJSONValue?
    ) throws -> (models: [CodexModelOption], nextCursor: String?) {
        guard let data = result?[external: "data"]?.externalArray else {
            throw ExternalAgentRuntimeError.protocolError("Codex model/list response has no data array.")
        }
        let models = try data.map { value -> CodexModelOption in
            guard let id = value[external: "id"]?.stringValue,
                  let model = value[external: "model"]?.stringValue
            else {
                throw ExternalAgentRuntimeError.protocolError(
                    "Codex model/list response contains an invalid model entry."
                )
            }
            let efforts = try (value[external: "supportedReasoningEfforts"]?.externalArray ?? []).map {
                effort -> CodexReasoningEffortOption in
                guard let reasoningEffort = effort[external: "reasoningEffort"]?.stringValue else {
                    throw ExternalAgentRuntimeError.protocolError(
                        "Codex model/list response contains an invalid reasoning effort."
                    )
                }
                return CodexReasoningEffortOption(
                    reasoningEffort: reasoningEffort,
                    description: effort[external: "description"]?.stringValue
                )
            }
            return CodexModelOption(
                id: id,
                model: model,
                displayName: value[external: "displayName"]?.stringValue ?? id,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: value[external: "defaultReasoningEffort"]?.stringValue,
                isDefault: value[external: "isDefault"]?.externalBool == true
            )
        }
        return (models, result?[external: "nextCursor"]?.stringValue)
    }
}

struct CodexModelCatalogClient: Sendable {
    private let executableURL: URL
    private let providerID: String?
    private let environment: [String: String]
    private let firstOutputTimeout: Duration

    init(
        executableURL: URL,
        providerID: String? = nil,
        environment: [String: String],
        // Codex 升级后可能需要丢弃旧模型缓存并在线刷新。实测 15 秒会与刷新完成
        // 发生竞态，因此目录查询使用独立的 45 秒边界，不影响正式 turn 的超时策略。
        firstOutputTimeout: Duration = .seconds(45)
    ) {
        self.executableURL = executableURL
        self.providerID = providerID
        self.environment = environment
        self.firstOutputTimeout = firstOutputTimeout
    }

    func load() async throws -> CodexModelCatalog {
        let resultBox = CodexModelCatalogResultBox()
        let driver = CodexModelCatalogDriver(
            executableURL: executableURL,
            providerID: providerID,
            environment: environment,
            resultBox: resultBox
        )
        let host = ExternalAgentRuntimeHost(firstOutputTimeout: firstOutputTimeout)
        try await host.execute(runID: UUID(), driver: driver) { _ in }
        return try resultBox.requiredCatalog()
    }
}

/// Driver 只负责 initialize 与分页 model/list，不创建 thread，也不会触发模型推理。
final class CodexModelCatalogDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration: ExternalAgentProcessConfiguration

    private static let initializeRequestID = 1
    private var nextRequestID = 2
    private var pendingModelListRequestID: Int?
    private var models: [CodexModelOption] = []
    private let resultBox: CodexModelCatalogResultBox

    init(
        executableURL: URL,
        providerID: String? = nil,
        environment: [String: String],
        resultBox: CodexModelCatalogResultBox
    ) {
        self.resultBox = resultBox
        processConfiguration = ExternalAgentProcessConfiguration(
            executableURL: executableURL,
            arguments: CodexRuntimeProcessArguments.appServer(providerID: providerID),
            environment: environment,
            currentDirectoryURL: FileManager.default.temporaryDirectory
        )
    }

    func initialFrames() throws -> [AgentJSONValue] {
        [
            .jsonRPCRequest(
                id: Self.initializeRequestID,
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("starcat"),
                        "title": .string("Starcat"),
                        "version": .string(
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                                ?? "development"
                        ),
                    ]),
                    "capabilities": .object(["experimentalApi": .bool(true)]),
                ])
            )
        ]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        guard let object = frame.externalObject else { throw ExternalAgentRuntimeError.invalidFrame }
        if let error = object["error"]?.externalObject {
            throw ExternalAgentRuntimeError.protocolError(
                error["message"]?.stringValue ?? "Codex model/list returned an unknown error."
            )
        }
        guard object["method"] == nil, let id = object["id"]?.integerValue else {
            return ExternalAgentProtocolOutput()
        }

        if id == Self.initializeRequestID {
            return ExternalAgentProtocolOutput(outboundFrames: [
                .jsonRPCNotification(method: "initialized"),
                makeModelListFrame(cursor: nil),
            ])
        }
        guard id == pendingModelListRequestID else { return ExternalAgentProtocolOutput() }

        let page = try CodexModelCatalog.parsePage(from: object["result"])
        models.append(contentsOf: page.models)
        if let nextCursor = page.nextCursor, !nextCursor.isEmpty {
            return ExternalAgentProtocolOutput(outboundFrames: [
                makeModelListFrame(cursor: nextCursor)
            ])
        }
        resultBox.store(CodexModelCatalog(models: models))
        return ExternalAgentProtocolOutput(events: [.completed], isTerminal: true)
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }

    private func makeModelListFrame(cursor: String?) -> AgentJSONValue {
        let requestID = nextRequestID
        nextRequestID += 1
        pendingModelListRequestID = requestID
        var params: [String: AgentJSONValue] = [
            "limit": .number(100),
            "includeHidden": .bool(false),
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return .jsonRPCRequest(id: requestID, method: "model/list", params: .object(params))
    }
}

/// Driver 是同步协议状态机；用一把窄锁把最终目录交给 async Client，避免 Task 转发
/// 造成 Host 已结束但目录尚未写入的竞态。锁内只做一次值拷贝，不执行 I/O。
final class CodexModelCatalogResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var catalog: CodexModelCatalog?

    func store(_ catalog: CodexModelCatalog) {
        lock.lock()
        self.catalog = catalog
        lock.unlock()
    }

    func requiredCatalog() throws -> CodexModelCatalog {
        lock.lock()
        let catalog = catalog
        lock.unlock()
        guard let catalog else {
            throw ExternalAgentRuntimeError.protocolError("Codex model/list completed without a catalog.")
        }
        return catalog
    }
}
