//
//  RAGCLIModelClient.swift
//  Starcat
//
//  Direct 版知识库 RAG 的受限 CLI 文本推理客户端。
//
//  关键边界：
//  - Starcat 仍负责检索、Embedding、Rerank、引用解析和持久化；CLI 只接收当前请求快照。
//  - 请求正文只通过 stdin 传递，不出现在进程参数或临时文件中。
//  - Claude Code 使用 `--tools ""`；Codex 忽略用户配置并关闭所有可用工具特性。
//  - 任何工具事件都会终止子进程，不能被当成普通文本吞掉。
//  - 子进程固定运行在 Starcat 的空临时目录，不能把 Starcat checkout 或数据库目录设为 cwd。
//

import Foundation
import Darwin

/// CLI 进程协议与输出格式。
enum RAGCLIProvider: String, Hashable, Sendable {
    case codex
    case claude

    init?(backend: RAGInferenceBackend) {
        switch backend {
        case .api: return nil
        case .codexCLI: self = .codex
        case .claudeCLI: self = .claude
        }
    }

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }

    var displayModelName: String {
        switch self {
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code CLI"
        }
    }
}

/// 本机 CLI 失败。面向用户的短文案走 String Catalog，`diagnosticDetail` 保留精确原因。
enum RAGCLIRuntimeError: Error, LocalizedError, Equatable, Sendable {
    case directOnly
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut(provider: String, seconds: Int)
    case processFailed(provider: String, status: Int32, detail: String)
    case invalidOutput(String)
    case prohibitedTool(String)
    case unsupportedImages
    case invalidHistory

    var errorDescription: String? {
        switch self {
        case .directOnly:
            return String.l10n("rag.cli.error.directOnly")
        case .executableNotFound(let name):
            return String(format: String.l10n("rag.cli.error.executableNotFoundFormat"), name)
        case .launchFailed:
            return String.l10n("rag.cli.error.launchFailed")
        case .timedOut:
            return String.l10n("rag.cli.error.timedOut")
        case .processFailed:
            return String.l10n("rag.cli.error.processFailed")
        case .invalidOutput:
            return String.l10n("rag.cli.error.invalidOutput")
        case .prohibitedTool:
            return String.l10n("rag.cli.error.prohibitedTool")
        case .unsupportedImages:
            return String.l10n("rag.cli.error.unsupportedImages")
        case .invalidHistory:
            return String.l10n("rag.cli.error.invalidHistory")
        }
    }

    var diagnosticDetail: String? {
        switch self {
        case .directOnly, .unsupportedImages, .invalidHistory:
            return nil
        case .executableNotFound(let name):
            return name
        case .launchFailed(let detail), .invalidOutput(let detail), .prohibitedTool(let detail):
            return detail
        case .timedOut(let provider, let seconds):
            return "\(provider) timed out after \(seconds)s"
        case .processFailed(let provider, let status, let detail):
            return "\(provider) exited with \(status): \(detail)"
        }
    }
}

/// 一次 CLI 调用的不可变快照。请求内容只在 `standardInput` 中，不参与命令行拼接。
struct RAGCLIInvocation: Equatable, Sendable {
    var provider: RAGCLIProvider
    var executableURL: URL
    var arguments: [String]
    var standardInput: Data
    var currentDirectoryURL: URL
    var displayModelName: String
}

/// CLI 二进制解析器。
///
/// Finder 启动的 GUI App 通常拿不到交互式 shell 的完整 PATH，因此先查继承 PATH，再查
/// Homebrew / npm / Claude 常见安装目录。这里只做自动探测，不执行 shell，也不读取配置文件。
struct RAGCLIExecutableResolver: Sendable {
    func resolve(_ provider: RAGCLIProvider) throws -> URL {
        let name = provider.executableName
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates: [URL] = []

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name)
            }
        }

        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            home.appendingPathComponent(".local/bin/\(name)"),
            home.appendingPathComponent(".npm-global/bin/\(name)"),
            home.appendingPathComponent(".bun/bin/\(name)"),
            home.appendingPathComponent(".claude/local/\(name)"),
        ]

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw RAGCLIRuntimeError.executableNotFound(name)
    }
}

/// 把 Starcat 的 Chat 请求转换成不依赖仓库和 MCP 的 CLI 调用。
struct RAGCLIInvocationFactory: Sendable {
    private static let fixedBoundaryInstruction = """
    You are a text-only inference engine embedded in Starcat Knowledge RAG.
    Never call tools, inspect files, run commands, browse, use MCP, or start subagents.
    Answer only from the request text supplied on standard input.
    """

    func make(
        provider: RAGCLIProvider,
        executableURL: URL,
        request: AIChatRequest,
        workingDirectory: URL
    ) throws -> RAGCLIInvocation {
        guard request.tools.isEmpty else {
            throw RAGCLIRuntimeError.prohibitedTool("request declared \(request.tools.count) tools")
        }
        guard request.images.isEmpty else { throw RAGCLIRuntimeError.unsupportedImages }
        guard request.history.allSatisfy({ $0.role != .tool && $0.toolCalls.isEmpty }) else {
            throw RAGCLIRuntimeError.invalidHistory
        }

        let arguments: [String]
        switch provider {
        case .codex:
            // `--ignore-user-config` 保留 Codex 登录态，但不加载用户 MCP / plugin 配置。
            // 关闭工具特性 + read-only sandbox 是双保险；解析层还会拒绝任何工具事件。
            arguments = [
                "exec",
                "--ignore-user-config",
                "--ignore-rules",
                "--json",
                "--ephemeral",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "--disable", "shell_tool",
                "--disable", "apps",
                "--disable", "browser_use",
                "--disable", "browser_use_external",
                "--disable", "browser_use_full_cdp_access",
                "--disable", "computer_use",
                "--disable", "image_generation",
                "--disable", "multi_agent",
                "--disable", "multi_agent_v2",
                "--disable", "skill_search",
                "--disable", "goals",
                "--color", "never",
                "-",
            ]
        case .claude:
            // `--safe-mode` 清掉 CLAUDE.md / skill / plugin / hook / MCP；`--tools ""` 再从
            // 协议层给出空工具集合，同时保留 Claude Code 自己的本机登录状态。
            arguments = [
                "-p",
                "--verbose",
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--safe-mode",
                "--tools", "",
                "--no-session-persistence",
                "--no-chrome",
                "--disable-slash-commands",
                "--permission-mode", "dontAsk",
                "--system-prompt", Self.fixedBoundaryInstruction,
            ]
        }

        return RAGCLIInvocation(
            provider: provider,
            executableURL: executableURL,
            arguments: arguments,
            standardInput: Data(renderedInput(request).utf8),
            currentDirectoryURL: workingDirectory,
            displayModelName: provider.displayModelName
        )
    }

    /// CLI print mode 没有 Starcat 的原生 messages 参数，因此用明确边界保留角色语义。
    private func renderedInput(_ request: AIChatRequest) -> String {
        let history = request.history.enumerated().map { index, message in
            "[\(index + 1)] \(message.role.rawValue.uppercased()):\n\(message.content)"
        }.joined(separator: "\n\n")
        let outputRequirement: String
        switch request.responseFormat {
        case .text:
            outputRequirement = "Return only the requested answer text."
        case .jsonObject:
            outputRequirement = "Return exactly one valid JSON object. Do not use Markdown fences or commentary."
        }
        return """
        <starcat-rag-request>
        <security-boundary>
        \(Self.fixedBoundaryInstruction)
        </security-boundary>

        <system-instructions>
        \(request.systemPrompt)
        </system-instructions>

        <conversation-history>
        \(history.isEmpty ? "<empty>" : history)
        </conversation-history>

        <user-request>
        \(request.userPrompt)
        </user-request>

        <output-requirement>
        \(outputRequirement)
        </output-requirement>
        </starcat-rag-request>
        """
    }
}

/// 单行 JSON/JSONL 的语义事件。保持纯函数输入输出，便于用固定样本覆盖协议回归。
enum RAGCLIParsedLine: Equatable, Sendable {
    case delta(String)
    case reasoningDelta(String)
    case reasoningCompleted
    case usage(AIChatUsage)
    case model(String)
    case failure(String)
    case prohibitedTool(String)
    case ignored
}

/// Codex JSONL 与 Claude stream-json 的最小解析器。
struct RAGCLIJSONLineParser: Sendable {
    let provider: RAGCLIProvider

    func parse(_ line: String) -> [RAGCLIParsedLine] {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else {
            return line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [.ignored]
                : [.failure("Invalid JSONL: \(String(line.prefix(512)))")]
        }
        switch provider {
        case .codex: return parseCodex(root: root, type: type)
        case .claude: return parseClaude(root: root, type: type)
        }
    }

    private func parseCodex(root: [String: Any], type: String) -> [RAGCLIParsedLine] {
        if type == "item.started" || type == "item.completed" || type == "item.updated" {
            guard let item = root["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [.ignored] }
            if itemType == "agent_message", let text = item["text"] as? String, !text.isEmpty {
                return [.delta(text)]
            }
            if Self.isToolItemType(itemType) { return [.prohibitedTool(itemType)] }
            return [.ignored]
        }
        if type == "turn.completed", let raw = root["usage"] as? [String: Any] {
            return [.usage(Self.usage(from: raw))]
        }
        if type == "turn.failed" || type == "error" {
            return [.failure(Self.errorMessage(root) ?? type)]
        }
        return [.ignored]
    }

    private func parseClaude(root: [String: Any], type: String) -> [RAGCLIParsedLine] {
        if type == "system", root["subtype"] as? String == "init" {
            if let tools = root["tools"] as? [Any], !tools.isEmpty {
                return [.prohibitedTool("Claude initialized with \(tools.count) tools")]
            }
            if let model = root["model"] as? String { return [.model(model)] }
            return [.ignored]
        }
        if type == "stream_event", let event = root["event"] as? [String: Any] {
            let eventType = event["type"] as? String
            if eventType == "content_block_start",
               let block = event["content_block"] as? [String: Any],
               let blockType = block["type"] as? String,
               blockType == "tool_use" || blockType == "server_tool_use" {
                return [.prohibitedTool(blockType)]
            }
            if eventType == "content_block_delta", let delta = event["delta"] as? [String: Any] {
                switch delta["type"] as? String {
                case "text_delta":
                    return (delta["text"] as? String).map { [.delta($0)] } ?? [.ignored]
                case "thinking_delta":
                    return (delta["thinking"] as? String).map { [.reasoningDelta($0)] } ?? [.ignored]
                case "input_json_delta", "tool_use_delta":
                    return [.prohibitedTool(delta["type"] as? String ?? "tool delta")]
                default:
                    return [.ignored]
                }
            }
            if eventType == "content_block_stop" { return [.reasoningCompleted] }
            if eventType == "message_delta", let raw = event["usage"] as? [String: Any] {
                return [.usage(Self.usage(from: raw))]
            }
            return [.ignored]
        }
        if type == "assistant", let message = root["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]],
           content.contains(where: { ($0["type"] as? String) == "tool_use" }) {
            return [.prohibitedTool("Claude assistant tool_use")]
        }
        if type == "result" {
            let isError = root["is_error"] as? Bool ?? false
            if isError || (root["subtype"] as? String) != "success" {
                return [.failure((root["result"] as? String) ?? Self.errorMessage(root) ?? "Claude request failed")]
            }
            var events: [RAGCLIParsedLine] = []
            if let raw = root["usage"] as? [String: Any] { events.append(.usage(Self.usage(from: raw))) }
            if let modelUsage = root["modelUsage"] as? [String: Any], let model = modelUsage.keys.sorted().first {
                events.append(.model(model))
            }
            return events.isEmpty ? [.ignored] : events
        }
        return [.ignored]
    }

    private static func isToolItemType(_ type: String) -> Bool {
        let normalized = type.lowercased()
        return normalized.contains("tool")
            || normalized.contains("command")
            || normalized.contains("shell")
            || normalized.contains("web_search")
            || normalized.contains("file_change")
    }

    private static func errorMessage(_ root: [String: Any]) -> String? {
        if let message = root["message"] as? String { return message }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return nil
    }

    private static func usage(from raw: [String: Any]) -> AIChatUsage {
        let input = int(raw["input_tokens"] ?? raw["inputTokens"])
        let output = int(raw["output_tokens"] ?? raw["outputTokens"])
        let cached = int(raw["cached_input_tokens"] ?? raw["cache_read_input_tokens"] ?? raw["cacheReadInputTokens"])
        let reasoning = int(raw["reasoning_output_tokens"] ?? raw["reasoningTokens"])
        return AIChatUsage(
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            reasoningTokens: reasoning,
            totalTokens: input + output
        )
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
}

/// 进程生命周期所有者。
///
/// `Process` / `Pipe` 不是 Sendable；本类用锁把可变状态封在一个明确边界内，并标记为
/// `@unchecked Sendable`。所有跨线程入口都先经过锁，finish / cancel / timeout 只能赢一次。
private final class RAGCLIProcessSession: @unchecked Sendable {
    private let lock = NSLock()
    private let invocation: RAGCLIInvocation
    private let timeout: TimeInterval
    private let continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
    private let parser: RAGCLIJSONLineParser
    private let process = Process()
    private let inputPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var answer = ""
    private var responseModel: String
    private var usage: AIChatUsage?
    private var reasoningOpen = false
    private var finished = false

    init(
        invocation: RAGCLIInvocation,
        timeout: TimeInterval,
        continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
    ) {
        self.invocation = invocation
        self.timeout = max(timeout, 1)
        self.continuation = continuation
        self.parser = RAGCLIJSONLineParser(provider: invocation.provider)
        self.responseModel = invocation.displayModelName
    }

    func start() {
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(status: process.terminationStatus)
        }

        do {
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: invocation.standardInput)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            fail(RAGCLIRuntimeError.launchFailed(error.localizedDescription), terminate: true)
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.timeoutIfNeeded()
        }
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        terminateProcess()
        continuation.finish(throwing: CancellationError())
    }

    private func receiveStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        stdoutBuffer.append(data)
        let lines = drainLinesLocked(flushTail: false)
        lock.unlock()
        lines.forEach(handleLine)
    }

    private func receiveStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if stderrBuffer.count < 32_768 {
            stderrBuffer.append(data.prefix(32_768 - stderrBuffer.count))
        }
        lock.unlock()
    }

    private func handleLine(_ line: String) {
        for parsed in parser.parse(line) {
            switch parsed {
            case .delta(let text):
                guard !text.isEmpty else { continue }
                lock.lock()
                guard !finished else { lock.unlock(); return }
                answer += text
                lock.unlock()
                continuation.yield(.delta(text))
            case .reasoningDelta(let text):
                guard !text.isEmpty else { continue }
                lock.lock()
                reasoningOpen = true
                lock.unlock()
                continuation.yield(.reasoningDelta(text))
            case .reasoningCompleted:
                lock.lock()
                let shouldYield = reasoningOpen
                reasoningOpen = false
                lock.unlock()
                if shouldYield { continuation.yield(.reasoningCompleted) }
            case .usage(let value):
                lock.lock()
                usage = value
                lock.unlock()
                continuation.yield(.usage(value))
            case .model(let value):
                lock.lock()
                responseModel = value
                lock.unlock()
            case .failure(let detail):
                fail(RAGCLIRuntimeError.invalidOutput(detail), terminate: true)
                return
            case .prohibitedTool(let detail):
                fail(RAGCLIRuntimeError.prohibitedTool(detail), terminate: true)
                return
            case .ignored:
                break
            }
        }
    }

    private func processDidTerminate(status: Int32) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        guard !finished else { lock.unlock(); return }
        let tailLines = drainLinesLocked(flushTail: true)
        lock.unlock()
        tailLines.forEach(handleLine)

        lock.lock()
        guard !finished else { lock.unlock(); return }
        let finalAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalModel = responseModel
        let finalUsage = usage
        let stderr = String(decoding: stderrBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0, !finalAnswer.isEmpty {
            finished = true
            lock.unlock()
            continuation.yield(.completed(AIChatResponse(
                content: finalAnswer,
                usage: finalUsage,
                model: finalModel,
                finishReason: "stop"
            )))
            continuation.finish()
            return
        }
        finished = true
        lock.unlock()

        if status == 0 {
            continuation.finish(throwing: AIClientError.emptyResponse)
        } else {
            continuation.finish(throwing: RAGCLIRuntimeError.processFailed(
                provider: invocation.provider.rawValue,
                status: status,
                detail: stderr.isEmpty ? "no stderr" : String(stderr.prefix(4_096))
            ))
        }
    }

    private func timeoutIfNeeded() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        terminateProcess()
        continuation.finish(throwing: RAGCLIRuntimeError.timedOut(
            provider: invocation.provider.rawValue,
            seconds: Int(timeout)
        ))
    }

    private func fail(_ error: Error, terminate: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        if terminate { terminateProcess() }
        continuation.finish(throwing: error)
    }

    private func terminateProcess() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(self.process.processIdentifier, SIGKILL)
        }
    }

    /// 按字节切 JSONL，避免 UTF-8 多字节字符恰好跨 Pipe chunk 时被替换字符破坏。
    private func drainLinesLocked(flushTail: Bool) -> [String] {
        var lines: [String] = []
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        if flushTail, !stdoutBuffer.isEmpty {
            let line = String(decoding: stdoutBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeAll(keepingCapacity: false)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

/// RAG 专用 CLI 文本客户端。
///
/// 本类型只实现 `AITextGenerating`，因此不会被普通 API Provider 列表、Embedding 或连接
/// 测试路径误用。每次调用使用独立临时会话，取消时直接终止对应子进程。
struct RAGCLIModelClient: AITextGenerating, Sendable {
    let backend: RAGInferenceBackend
    let distributionGate: DistributionGate
    let timeout: TimeInterval

    init(
        backend: RAGInferenceBackend,
        distributionGate: DistributionGate,
        timeout: TimeInterval
    ) {
        self.backend = backend
        self.distributionGate = distributionGate
        self.timeout = timeout
    }

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        var answer = ""
        var completed: AIChatResponse?
        var usage: AIChatUsage?
        for try await event in chatStream(request: request) {
            switch event {
            case .delta(let text): answer += text
            case .usage(let value): usage = value
            case .completed(let response): completed = response
            case .reasoningDelta, .reasoningCompleted, .toolCallDelta: break
            }
        }
        if let completed { return completed }
        let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AIClientError.emptyResponse }
        return AIChatResponse(
            content: normalized,
            usage: usage,
            model: backend.runtimeModelName,
            finishReason: "stop"
        )
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                guard backend.isCLI, let provider = RAGCLIProvider(backend: backend) else {
                    throw RAGCLIRuntimeError.invalidOutput("API backend cannot create a CLI process")
                }
                do {
                    try distributionGate.requireDirect(.externalToolBridge)
                } catch {
                    throw RAGCLIRuntimeError.directOnly
                }
                let fileManager = FileManager.default
                let workingDirectory = fileManager.temporaryDirectory
                    .appendingPathComponent("Starcat-RAG-CLI", isDirectory: true)
                try fileManager.createDirectory(
                    at: workingDirectory,
                    withIntermediateDirectories: true
                )
                let executableURL = try RAGCLIExecutableResolver().resolve(provider)
                let invocation = try RAGCLIInvocationFactory().make(
                    provider: provider,
                    executableURL: executableURL,
                    request: request,
                    workingDirectory: workingDirectory
                )
                let session = RAGCLIProcessSession(
                    invocation: invocation,
                    timeout: timeout,
                    continuation: continuation
                )
                continuation.onTermination = { @Sendable _ in session.cancel() }
                session.start()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
