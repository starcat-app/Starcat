//
//  LocalMLXRuntime.swift
//  Starcat
//
//  MLX 推理运行时：模型容器懒加载 + 卸载 + 三类推理（LLM / Embedding / Rerank）。
//
//  并发模型（关键约束）：
//  - FIFO 准入覆盖加载、推理与收尾，防止 actor 重入造成重复加载；不同 ChatSession
//    可以并行，所以上游容器的锁不能代替应用级准入。
//  - actor 可在 await 时处理取消/快照；卸载先取消目标工作，再等待准入权后清理。
//  - 同一时间最多各驻留一个 LLM / Embedding / Reranker 容器；目录变了就重载
//    （同一时刻系统里只有一个激活的本地模型版本）。
//  - 内存压力（`DispatchSourceMemoryPressure` .warning / .critical）触发 `unloadAll`。
//    测试环境（TestEnvironment）下 shared 是惰性 no-op：任何加载都会抛错而不是真的
//    去碰 MLX / Metal。
//

import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import MLXEmbedders
import MLXRerankers
import MLXHuggingFace
// 宏展开会直接引用 HuggingFace / Tokenizers 的类型（HubClient / AutoTokenizer），
// 仅 import MLXHuggingFace 不够，必须同时引入两个实现包。
import HuggingFace
import Tokenizers

actor LocalMLXRuntime {

    static let shared = LocalMLXRuntime()

    private var llmContainer: ModelContainer?
    private var llmDirectoryID: String?
    private var embedderContainer: EmbedderModelContainer?
    private var embedderDirectoryID: String?
    private var rerankerContainer: RerankerContainer?
    private var rerankerDirectoryID: String?
    /// 每个驻留容器对应的跨进程共享读锁。必须晚于容器引用释放，避免另一个渠道
    /// 在 MLX 仍 mmap 权重时删除模型目录。
    private var modelAccessLeases: [LocalAIModelType: LocalAIModelAccessLease] = [:]
    private let gate = LocalAIOperationGate()
    private var residents: [LocalAIModelType: LocalAIResidentModel] = [:]
    private var generations: [LocalAIModelType: Int] = [:]
    private var unloading: Set<LocalAIModelType> = []
    private var queuedCount = 0
    private var activeType: LocalAIModelType?
    private var cancelActive: (@Sendable () -> Void)?
    private var initialized = false
    private var monitor: Task<Void, Never>?
    private var notice: String?
    private var releaseAfterOperation: Set<LocalAIModelType> = []
    private var loadStartedAt: [LocalAIModelType: TimeInterval] = [:]
    private let budget = LocalAIMemoryPolicy.budget(
        physicalMemory: ProcessInfo.processInfo.physicalMemory)

    private nonisolated(unsafe) var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private init() {
        installMemoryPressureHandler()
    }

    /// 容器不再逃逸给调用者：持有准入权直到完整推理流消费完，卸载才有确定的边界。
    func withLLM<T: Sendable>(
        directory: URL, operation: @escaping @Sendable (ModelContainer) async throws -> T
    ) async throws -> T {
        try await perform(type: .llm, directory: directory) {
            let container = try await self.llmContainer(directory: directory)
            try await self.markRunning(.llm)
            return try await operation(container)
        }
    }

    func withEmbedder<T: Sendable>(
        directory: URL, operation: @escaping @Sendable (EmbedderModelContainer) async throws -> T
    ) async throws -> T {
        try await perform(type: .embedding, directory: directory) {
            let container = try await self.embedderContainer(directory: directory)
            try await self.markRunning(.embedding)
            return try await operation(container)
        }
    }

    func withReranker<T: Sendable>(
        directory: URL, operation: @escaping @Sendable (RerankerContainer) async throws -> T
    ) async throws -> T {
        try await perform(type: .reranker, directory: directory) {
            let container = try await self.rerankerContainer(directory: directory)
            try await self.markRunning(.reranker)
            return try await operation(container)
        }
    }

    /// 下载后检查与面板手动加载共用同一队列，不能绕过加载防重。
    func preload(entry: LocalAIModelCatalogEntry, directory: URL) async throws {
        try await perform(type: entry.type, directory: directory, feature: "model.load") {
            switch entry.type {
            case .llm: _ = try await self.llmContainer(directory: directory)
            case .embedding: _ = try await self.embedderContainer(directory: directory)
            case .reranker: _ = try await self.rerankerContainer(directory: directory)
            }
        }
    }

    private func markRunning(_ type: LocalAIModelType) throws {
        // 工厂加载不一定及时响应取消，卸载发生后不能再启动一次昂贵的 prefill。
        try Task.checkCancellation()
        residents[type]?.phase = .running
        LocalAILog.record("inference.started", "Model is ready; inference started.", fields: memoryLogFields())
    }

    private func perform<T: Sendable>(
        type: LocalAIModelType, directory: URL, feature: String = "inference",
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let context = LocalAILogContext.current ?? .model(directory: directory, feature: feature)
        return try await LocalAILogContext.$current.withValue(context) {
            do { return try await performRecorded(type: type, operation: operation) }
            catch {
                LocalAILog.record("runtime.failed", "Local runtime operation ended without a result.",
                                  level: error is CancellationError ? .info : .error, fields: LocalAILogEvent.errorFields(error))
                throw error
            }
        }
    }

    /// 日志不新增 await：保持原有加载/准入/取消的原子边界，不改变模型生命周期。
    private func performRecorded<T: Sendable>(
        type: LocalAIModelType, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try ensureRuntimeAvailable()
        guard !unloading.contains(type) else { throw CancellationError() }
        let generation = generations[type, default: 0]
        queuedCount += 1
        let queuedAt = ProcessInfo.processInfo.systemUptime
        LocalAILog.record("queue.entered", "Waiting for local inference admission.", fields: ["queued": String(queuedCount)])
        do { try await gate.acquire() } catch {
            queuedCount -= 1
            throw error
        }
        queuedCount -= 1
        // 排队期间的卸载使旧请求失效，即便卸载已经完成也不能让旧请求重新加载。
        guard !Task.isCancelled, generation == generations[type, default: 0], !unloading.contains(type)
        else {
            await gate.release()
            throw CancellationError()
        }
        configureMemoryIfNeeded()
        LocalAILog.record("queue.admitted", "Local inference admission acquired.", fields: [
            "waitSeconds": LocalAILogEvent.seconds(ProcessInfo.processInfo.systemUptime - queuedAt)
        ])
        notice = nil
        activeType = type
        // 只为已取得准入权的请求开一个轻量心跳；排队请求不各自创建监控任务。
        // 心跳不持有模型容器，退出时取消，不能延长权重驻留时间。
        let admittedAt = ProcessInfo.processInfo.systemUptime
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let snapshot = await self?.snapshot(), !Task.isCancelled else { return }
                LocalAILog.record("runtime.progress", "Local model operation is active.", fields: [
                    "phase": String(describing: snapshot.models[type]?.phase ?? .notLoaded),
                    "elapsedSeconds": LocalAILogEvent.seconds(ProcessInfo.processInfo.systemUptime - admittedAt),
                    "mlxActiveBytes": String(snapshot.activeBytes), "mlxCacheBytes": String(snapshot.cacheBytes)
                ])
            }
        }
        defer { progress.cancel() }
        let task = Task { try await operation() }
        cancelActive = { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        cancelActive = nil
        activeType = nil
        if case .failure(let error) = result, residents[type]?.phase == .loading {
            residents[type]?.phase = .failed
            residents[type]?.error = error.localizedDescription
            // 工厂加载失败时没有可用容器，不能把读锁一直留到闲置回收。
            modelAccessLeases.removeValue(forKey: type)?.release()
            LocalAILog.record("model.load.failed", "Model loading ended without a usable container.",
                              level: error is CancellationError ? .info : .error,
                              fields: LocalAILogEvent.errorFields(error))
            loadStartedAt.removeValue(forKey: type)
        }
        if residents[type]?.phase == .running { residents[type]?.phase = .ready }
        residents[type]?.lastUsed = Date()
        if releaseAfterOperation.remove(type) != nil { clearContainer(type, reason: "configuration_changed") }
        // 上游流结束会等待 GPU 完成；在该边界归还可回收缓冲，不能只释放 Swift 引用。
        Memory.clearCache()
        LocalAILog.record("runtime.released", "Inference worker exited; reclaimable cache cleared.", fields: memoryLogFields())
        await gate.release()
        try Task.checkCancellation()
        // 重复保护也会取消 producer 来停止 GPU 工作，但必须保留它的真实失败原因。
        // 只有底层被取消却仍返回成功时才转成取消；外部父任务取消已由上行检查优先处理。
        if task.isCancelled, case .success = result { throw CancellationError() }
        return try result.get()
    }

    private func configureMemoryIfNeeded() {
        if !initialized {
            initialized = true
            Memory.cacheLimit = LocalAIMemoryPolicy.cacheBytes
            Memory.memoryLimit = budget
            LocalAILog.record("runtime.configured", "MLX memory limits configured.", fields: memoryLogFields())
        }
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            // monitor 比请求活得更久，不能把后续闲置卸载归到首次请求名下。
            await LocalAILogContext.$current.withValue(nil) {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    await self?.checkMemoryAndIdleModels()
                }
            }
        }
    }

    /// 快照不主动初始化 Metal。Laya 使用独立容器，但共享同一套 MLX 进程级统计；
    /// 只有它已经初始化 MLX 时，状态面板才通过参数读取全局内存。
    func snapshot(includeExternallyInitializedMemory: Bool = false) -> LocalAIRuntimeSnapshot {
        var result = LocalAIRuntimeSnapshot(
            models: residents, budgetBytes: budget, queuedCount: queuedCount, notice: notice)
        if initialized || includeExternallyInitializedMemory {
            result.activeBytes = Memory.activeMemory
            result.cacheBytes = Memory.cacheMemory
            result.peakBytes = Memory.peakMemory
        }
        return result
    }

    private func beginLoading(_ type: LocalAIModelType, directory: URL) async throws -> Int {
        clearContainer(type)
        Memory.clearCache()
        residents[type] = .init(directory: directory, phase: .loading)
        loadStartedAt[type] = ProcessInfo.processInfo.systemUptime
        LocalAILog.record("model.load.started", "Loading model weights and tokenizer.", fields: [
            "modelDirectory": directory.lastPathComponent, "budgetBytes": String(budget)
        ])
        if let entry = LocalAIModelCatalog.entries.first(where: {
            directory.lastPathComponent.hasPrefix($0.id + "@")
        }) {
            guard entry.memoryRecommendation <= UInt64(budget) else {
                throw LocalAIError.memoryBudgetExceeded
            }
            // 只在准入权内驱逐闲置模型，避免三类权重常驻超过整机预算。
            if Memory.activeMemory + Int(entry.memoryRecommendation) > budget {
                for other in LocalAIModelType.allCases where other != type { clearContainer(other, reason: "memory_budget") }
                Memory.clearCache()
            }
        }
        // 目录检查与实际权重读取必须处于同一个租约内；只在工厂 load 之前检查存在
        // 仍有 TOCTOU 窗口，另一渠道可能紧接着删除。
        modelAccessLeases[type] = try await LocalAISharedModelCoordinator.shared
            .acquireModelRead(at: directory)
        return Memory.activeMemory
    }

    private func didLoad(_ type: LocalAIModelType, previousBytes: Int) {
        residents[type]?.loadedBytes = max(0, Memory.activeMemory - previousBytes)
        residents[type]?.phase = .ready
        var fields = memoryLogFields()
        fields["loadedBytes"] = String(residents[type]?.loadedBytes ?? 0)
        if let started = loadStartedAt.removeValue(forKey: type) {
            fields["durationSeconds"] = LocalAILogEvent.seconds(ProcessInfo.processInfo.systemUptime - started)
        }
        LocalAILog.record("model.load.completed", "Model loaded successfully.", fields: fields)
    }

    // MARK: - 容器管理

    /// LLM 容器（懒加载 + 目录变化重载）。
    private func llmContainer(directory: URL) async throws -> ModelContainer {
        if let container = llmContainer, llmDirectoryID == directory.path {
            LocalAILog.record("model.reused", "Reusing resident generation model.")
            return container
        }
        let before = try await beginLoading(.llm, directory: directory)
        try ensureRuntimeAvailable()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: Self.tokenizerLoader)
        llmContainer = container
        llmDirectoryID = directory.path
        didLoad(.llm, previousBytes: before)
        return container
    }

    /// Embedding 容器。
    private func embedderContainer(directory: URL) async throws -> EmbedderModelContainer {
        if let container = embedderContainer, embedderDirectoryID == directory.path {
            LocalAILog.record("model.reused", "Reusing resident embedding model.")
            return container
        }
        let before = try await beginLoading(.embedding, directory: directory)
        try ensureRuntimeAvailable()
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: directory,
            using: Self.tokenizerLoader)
        embedderContainer = container
        embedderDirectoryID = directory.path
        didLoad(.embedding, previousBytes: before)
        return container
    }

    /// Reranker 容器。`RerankerModelFactory` 按 config.json 自动选择 encoder / qwen3 / jina 实现。
    private func rerankerContainer(directory: URL) async throws -> RerankerContainer {
        if let container = rerankerContainer, rerankerDirectoryID == directory.path {
            LocalAILog.record("model.reused", "Reusing resident reranker model.")
            return container
        }
        let before = try await beginLoading(.reranker, directory: directory)
        try ensureRuntimeAvailable()
        let container = try await RerankerModelFactory.shared.loadContainer(
            from: directory,
            using: Self.tokenizerLoader,
            allowUnverifiedModel: false)
        rerankerContainer = container
        rerankerDirectoryID = directory.path
        didLoad(.reranker, previousBytes: before)
        return container
    }

    /// 卸载全部容器（内存压力 / 用户关闭 Local AI 时调用）。
    func unloadAll(reason: String = "manual") async {
        await unload(types: Set(LocalAIModelType.allCases), reason: reason)
    }

    /// 对正在工作的目标先取消，再等工作实际退出。其它类型不会被取消。
    func unload(types: Set<LocalAIModelType>, reason: String = "manual") async {
        let targets = types.subtracting(unloading)
        guard !targets.isEmpty else { return }
        unloading.formUnion(targets)
        var contexts: [LocalAIModelType: LocalAILogContext] = [:]
        for type in targets {
            if let model = residents[type], model.phase != .unloaded {
                let context = LocalAILogContext.model(directory: model.directory, feature: "model.unload")
                contexts[type] = context
                LocalAILog.record("model.unload.requested", "Unload requested; waiting for active work to exit.",
                                  context: context, fields: ["reason": reason])
            }
            generations[type, default: 0] += 1
            residents[type]?.phase = .unloading
        }
        if let activeType, targets.contains(activeType) { cancelActive?() }
        do { try await gate.acquire() } catch {
            unloading.subtract(targets)
            return
        }
        for type in targets { clearContainer(type, reason: reason, context: contexts[type]) }
        if initialized { Memory.clearCache() }
        unloading.subtract(targets)
        await gate.release()
    }

    private func clearContainer(
        _ type: LocalAIModelType, reason: String = "model_replaced", context: LocalAILogContext? = nil
    ) {
        let previous = residents[type]
        switch type {
        case .llm:
            llmContainer = nil
            llmDirectoryID = nil
        case .embedding:
            embedderContainer = nil
            embedderDirectoryID = nil
        case .reranker:
            rerankerContainer = nil
            rerankerDirectoryID = nil
        }
        // 先清空容器，再放行文件删除；顺序反过来会让另一进程看见“可删”但本进程
        // 仍持有 mmap / tokenizer 文件引用。
        modelAccessLeases.removeValue(forKey: type)?.release()
        residents[type]?.phase = .unloaded
        residents[type]?.loadedBytes = 0
        loadStartedAt.removeValue(forKey: type)
        if let previous, previous.phase != .unloaded {
            var fields = memoryLogFields()
            fields["reason"] = reason
            LocalAILog.record("model.unloaded", "Model container released.",
                              context: context ?? .model(directory: previous.directory, feature: "model.unload"), fields: fields)
        }
    }

    func clearMemoryCache(includeExternallyInitializedMemory: Bool = false) {
        if initialized || includeExternallyInitializedMemory { Memory.clearCache() }
        LocalAILog.record(
            "memory.cache.cleared",
            "Reclaimable MLX cache cleared manually.",
            fields: memoryLogFields(
                includeExternallyInitializedMemory: includeExternallyInitializedMemory
            )
        )
    }

    /// MLX 统计不是整个进程内存；尚未初始化时不能为了日志触发 Metal 初始化。
    private func memoryLogFields(
        includeExternallyInitializedMemory: Bool = false
    ) -> [String: String] {
        var result = ["budgetBytes": String(budget)]
        if initialized || includeExternallyInitializedMemory {
            result["mlxActiveBytes"] = String(Memory.activeMemory)
            result["mlxCacheBytes"] = String(Memory.cacheMemory)
        }
        return result
    }

    /// 配置切到远端时仅回收无人使用的模型；在途本地请求完成后再释放，不中断其它功能。
    func releaseUnusedModels(keeping names: Set<String>) async {
        for (type, model) in residents {
            let entry = LocalAIModelCatalog.entries.first {
                model.directory.lastPathComponent.hasPrefix($0.id + "@")
            }
            guard let entry, !names.contains(entry.displayName) else {
                releaseAfterOperation.remove(type)
                continue
            }
            if activeType == type {
                releaseAfterOperation.insert(type)
                LocalAILog.record("model.unload.deferred", "Configuration changed; unload will follow active work.",
                                  context: .model(directory: model.directory, feature: "model.unload"))
            } else {
                await unload(types: [type], reason: "configuration_changed")
            }
        }
    }

    private func checkMemoryAndIdleModels() async {
        guard initialized else { return }
        if Memory.activeMemory + Memory.cacheMemory > budget {
            await handleMemoryPressure()
            return
        }
        let idle = Set(
            residents.compactMap { type, model in
                model.phase == .ready
                    && Date().timeIntervalSince(model.lastUsed) >= LocalAIMemoryPolicy.idleSeconds
                    ? type : nil
            })
        // 后台回收只在整条 GPU 队列空闲时执行，不能让旧模型的回收挡住新的业务请求。
        if !idle.isEmpty, activeType == nil, queuedCount == 0 { await unload(types: idle, reason: "idle_timeout") }
        if activeType == nil, queuedCount == 0,
            residents.values.allSatisfy({ $0.phase == .unloaded || $0.phase == .failed })
        {
            monitor?.cancel()
            monitor = nil
        }
    }

    private func handleMemoryPressure() async {
        LocalAILog.record("memory.pressure", "Memory pressure detected; unloading local models.", level: .warning,
                          context: nil, fields: memoryLogFields())
        await unloadAll(reason: "memory_pressure")
        notice = String.l10n("toolbar.localai.memoryPressure")
    }

    private func ensureRuntimeAvailable() throws {
        guard LocalAIHardwareSupport.isLocalAIAvailable else {
            throw LocalAIError.hardwareUnsupported
        }
        guard !TestEnvironment.isRunning else {
            throw LocalAIError.unavailableInTests
        }
    }

    /// 系统内存压力必须取消工作并清理缓存；仅置 nil 时运行中的 session 仍持有模型。
    /// actor init 是 nonisolated 的，本函数也保持 nonisolated（只操作源对象自身）。
    private nonisolated func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.handleMemoryPressure() }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// TokenizerLoader：mlx-swift-lm 3.x 起不内置分词器实现，按官方文档用
    /// MLXHuggingFace 宏桥接 swift-transformers（模型权重由 Starcat 自己下载到本地，
    /// 因此永远不需要 Downloader）。
    nonisolated static let tokenizerLoader: any TokenizerLoader = #huggingFaceTokenizerLoader()
}

// MARK: - 生成流构造

extension LocalMLXRuntime {

    /// 把一次 AIChatRequest 变成 ChatSession 流。
    ///
    /// 每次 request 独立 ChatSession：Starcat 的业务层把每次调用当独立请求（多轮靠
    /// 显式 history），不复用 KV cache；这样最简单也最不容易串会话。
    ///
    /// `nonisolated`：session / stream 在调用方上下文创建与迭代，避免把长生成挂在
    /// actor 上（见文件头「并发模型」）。
    nonisolated static func generate(
        container: ModelContainer,
        request originalRequest: AIChatRequest,
        onEvent: @escaping @Sendable (AIChatStreamEvent) -> Void
    ) async throws -> AIChatResponse {
        if !originalRequest.tools.isEmpty {
            throw LocalAIError.toolsUnsupported
        }
        LocalAILog.record("input.preparing", "Preparing chat template and validating the input token budget.")
        let prepared = try await RepoAIChatContextBudget.prepare(originalRequest) { candidate in
            try await Self.promptTokenCount(container: container, request: candidate)
        }
        let request = prepared?.request ?? originalRequest
        if let prepared {
            LocalAILog.record("context.prepared", "Repository chat context selected within the model input budget.", fields: [
                "inputTokens": String(prepared.inputTokens),
                "inputTokenLimit": String(LocalAIGenerationPolicy.chatInputTokens),
                "contextWindowTokens": String(LocalAIGenerationPolicy.chatContextTokens),
                "reservedOutputTokens": String(LocalAIGenerationPolicy.chatOutputTokens),
                "compacted": String(prepared.wasCompacted)
            ])
        }
        let inputTokenLimit = prepared == nil ? LocalAIMemoryPolicy.inputTokens : LocalAIGenerationPolicy.chatInputTokens
        let outputTokenLimit = prepared == nil ? LocalAIMemoryPolicy.outputTokens : LocalAIGenerationPolicy.chatOutputTokens
        let cacheTokenLimit = prepared == nil
            ? LocalAIMemoryPolicy.inputTokens + LocalAIMemoryPolicy.outputTokens
            : LocalAIGenerationPolicy.chatContextTokens
        let reasoningConfiguration = await container.configuration.reasoningConfig
        let reasoningSetup = Self.reasoningSetup(
            configuration: reasoningConfiguration,
            disableThinking: request.disableThinking)
        let systemPrompt = Self.generationSystemPrompt(for: request)
        let parameters = GenerateParameters(
            maxTokens: min(max(request.parameters.maxCompletionTokens, 1), outputTokenLimit),
            maxKVSize: cacheTokenLimit,
            temperature: Float(request.parameters.temperature),
            topP: Float(request.parameters.topP),
            topK: request.parameters.topK,
            minP: 0,
            repetitionPenalty: request.model == LocalAIModelCatalog.llmMiniCPM5.displayName ? 1.05 : nil,
            repetitionContextSize: 512,
            presencePenalty: request.model.hasPrefix("Qwen3") ? 1.5 : nil,
            presenceContextSize: 512,
            prefill: .init(stepSize: 128))
        // 注意：Starcat 模块里已有内部的 `ChatSession`（RepoAIChatViewModel 的
        // 聊天历史模型），它在本文件作用域里遮蔽 MLXLMCommon.ChatSession，
        // 必须用模块限定名。
        let session = MLXLMCommon.ChatSession(
            container,
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            generateParameters: parameters,
            additionalContext: reasoningSetup.additionalContext)

        let messages = try Self.chatMessages(for: request)
        // 聊天已按完整模板真实分词；其它任务继续使用既有 8K 输入准入，不改其语义。
        let promptTokenCount: Int
        if let prepared { promptTokenCount = prepared.inputTokens }
        else { promptTokenCount = try await Self.promptTokenCount(container: container, request: request) }
        LocalAILog.record("input.prepared", "Input token budget validated.", fields: [
            "inputTokens": String(promptTokenCount),
            "inputTokenLimit": String(inputTokenLimit)
        ])
        guard promptTokenCount <= inputTokenLimit else {
            throw LocalAIError.contextTooLong
        }
        var output = ""
        var reasoningOutput = ""
        var completion: GenerateCompletionInfo?
        var repetitionGuard = LocalAIRepetitionGuard()
        let generationStartedAt = ProcessInfo.processInfo.systemUptime
        var sawFirstOutput = false
        var sawReasoning = false
        var sawAnswer = false
        var reasoningRouter = AIStreamReasoningNormalizer(
            openingTag: reasoningConfiguration?.startDelimiter ?? "<think>",
            closingTag: reasoningConfiguration?.endDelimiter ?? "</think>",
            startsInsideReasoning: reasoningSetup.startsInsideReasoning)
        var iterator = session.streamDetails(to: messages).makeAsyncIterator()
        LocalAILog.record("generation.waiting", "Waiting for the first generated output.")
        do {
            while let generation = try await iterator.next() {
                try Task.checkCancellation()
                if let info = generation.info {
                    completion = info
                    continue
                }
                guard let chunk = generation.chunk else { throw LocalAIError.toolsUnsupported }
                if !sawFirstOutput, !chunk.isEmpty {
                    sawFirstOutput = true
                    LocalAILog.record("generation.first-output", "First generated output received.", fields: [
                        "latencySeconds": LocalAILogEvent.seconds(ProcessInfo.processInfo.systemUptime - generationStartedAt)
                    ])
                }
                guard !repetitionGuard.ingest(chunk) else { throw LocalAIError.repetitiveOutput }
                for event in reasoningRouter.ingest(content: chunk, nativeReasoning: nil) {
                    switch event {
                    case .reasoningDelta(let text):
                        if !sawReasoning {
                            sawReasoning = true
                            LocalAILog.record("generation.reasoning", "Reasoning phase started; reasoning text is not logged.")
                        }
                        reasoningOutput += text
                    case .delta(let text):
                        if !sawAnswer {
                            sawAnswer = true
                            LocalAILog.record("generation.answer", "Final answer output started; answer text is not logged.")
                        }
                        output += text
                    default:
                        break
                    }
                    onEvent(event)
                }
            }
        } catch {
            // 这里运行在 LocalMLXClient 的独立生成子任务内。普通 throw 不等价于取消
            // AsyncStream 的 producer；取消并推进一次 iterator，确保 SDK 的 onTermination
            // 已通知底层停止，再等待 GPU 锁归还。保留原始错误，不能把重复误报为用户取消。
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try? await iterator.next()
            LocalAILog.record("generation.cleanup", "Waiting for the cancelled inference worker to exit.")
            await session.synchronize()
            await session.clear()
            throw error
        }
        // AsyncStream 取消早于底层 GPU 任务退出；等待 session 的锁归还后才释放准入。
        await session.synchronize()
        await session.clear()
        try Task.checkCancellation()
        for event in reasoningRouter.finish() {
            switch event {
            case .reasoningDelta(let text):
                reasoningOutput += text
            case .delta(let text):
                output += text
            default:
                break
            }
            onEvent(event)
        }
        guard let completion else { throw AIClientError.emptyResponse }
        let finishReason: String
        switch completion.stopReason {
        case .stop: finishReason = "stop"
        case .length: finishReason = "length"
        case .cancelled: throw CancellationError()
        }
        let usage = AIChatUsage(
            inputTokens: completion.promptTokenCount,
            outputTokens: completion.generationTokenCount,
            cachedTokens: 0,
            reasoningTokens: 0,
            totalTokens: completion.promptTokenCount + completion.generationTokenCount,
            repositoryContextCompacted: prepared?.wasCompacted ?? false)
        LocalAILog.record("generation.completed", "MLX generation completed and session resources were released.", fields: [
            "finishReason": finishReason, "inputTokens": String(completion.promptTokenCount),
            "outputTokens": String(completion.generationTokenCount),
            "durationSeconds": LocalAILogEvent.seconds(ProcessInfo.processInfo.systemUptime - generationStartedAt)
        ])
        onEvent(.usage(usage))
        return AIChatResponse(
            content: output,
            reasoningContent: reasoningOutput.isEmpty ? nil : reasoningOutput,
            usage: usage,
            model: request.model,
            finishReason: finishReason)
    }

    /// 与实际 ChatSession 使用同一模板、JSON 约束及 thinking 标志，不能只计算正文。
    /// UserInput / Chat.Message 在容器内创建，只返回整数，不跨 actor 共享可变 MLX 对象。
    private nonisolated static func promptTokenCount(container: ModelContainer, request: AIChatRequest) async throws -> Int {
        try await container.perform { context in
            let setup = Self.reasoningSetup(configuration: context.configuration.reasoningConfig,
                                            disableThinking: request.disableThinking)
            let history = try Self.chatMessages(for: request)
            let prompt = Self.generationSystemPrompt(for: request)
            let messages = prompt.isEmpty ? history : [.system(prompt)] + history
            let prepared = try await context.processor.prepare(
                input: UserInput(chat: messages, additionalContext: setup.additionalContext))
            return prepared.text.tokens.size
        }
    }

    /// JSON 模式仍靠模板约束。分词与生成调用同一入口，避免漏算这段额外指令。
    private nonisolated static func generationSystemPrompt(for request: AIChatRequest) -> String {
        guard request.responseFormat == .jsonObject else { return request.systemPrompt }
        return request.systemPrompt
            + "\n\nIMPORTANT: Respond with a single valid JSON value only. No markdown fences, no commentary."
    }

    /// 把请求级 `disableThinking` 映射到模型自己的 chat-template 开关。
    ///
    /// 可关闭模型（例如 Qwen 的 `enable_thinking`）直接关闭；强制思考模型不能因为短任务
    /// 请求关闭思考就整次失败，此时继续生成并依赖下游 router 隔离 reasoning。这样翻译、
    /// 评论等任务优先走快速路径，同时仍兼容 always-on reasoning 模型。
    private nonisolated static func reasoningSetup(
        configuration: ReasoningConfig?,
        disableThinking: Bool
    ) -> (additionalContext: [String: any Sendable]?, startsInsideReasoning: Bool) {
        guard let configuration else { return (nil, false) }

        if disableThinking {
            do {
                let context = try configuration.promptStrategy.additionalContext(
                    forThinkingEnabled: false)
                return (context, false)
            } catch ReasoningError.cannotDisableReasoning {
                // 强制思考不是请求失败条件；思考内容仍会被分流，业务层只收到最终答案。
                return (nil, true)
            } catch {
                // ReasoningPromptStrategy 当前只有上述 typed error。保留安全兜底，避免未来
                // 依赖新增错误时把模型原始思考误当正文；继续按 reasoning 模型处理。
                return (nil, true)
            }
        }

        let context = try? configuration.promptStrategy.additionalContext(
            forThinkingEnabled: nil)
        let startsInsideReasoning: Bool
        switch configuration.promptStrategy {
        case .templateFlag(_, let defaultOn):
            startsInsideReasoning = defaultOn
        case .alwaysOn, .none:
            startsInsideReasoning = true
        }
        return (context, startsInsideReasoning)
    }

    /// AIChatRequest → Chat.Message 数组。本地 v1 只支持 user/assistant 历史；
    /// tool 消息链（Agent Runtime）明确报不支持。
    private static func chatMessages(for request: AIChatRequest) throws -> [Chat.Message] {
        var messages: [Chat.Message] = []
        for historyMessage in request.history {
            switch historyMessage.role {
            case .user:
                messages.append(.user(historyMessage.content))
            case .assistant:
                messages.append(.assistant(historyMessage.content))
            case .tool:
                throw LocalAIError.toolsUnsupported
            }
        }
        messages.append(.user(request.userPrompt))
        return messages
    }
}

// MARK: - 错误

/// 本地 AI 专用错误。`errorDescription` 走设置页 / AI 错误弹层通用文案通道。
enum LocalAIError: LocalizedError, Equatable {
    case hardwareUnsupported
    case unavailableInTests
    case modelNotInstalled(String)
    case toolsUnsupported
    case repetitiveOutput
    case memoryBudgetExceeded
    case contextTooLong
    case embeddingDimensionMismatch(expected: Int, actual: Int)
    case repositoryChatInputTooLong

    var errorDescription: String? {
        switch self {
        case .hardwareUnsupported:
            return String.l10n("settings.localai.error.hardwareUnsupported")
        case .unavailableInTests:
            return "Local AI is unavailable in tests"
        case .modelNotInstalled(let name):
            return String(
                format: String.l10n("settings.localai.error.modelNotInstalledFormat"), name)
        case .toolsUnsupported:
            return String.l10n("settings.localai.error.toolsUnsupported")
        case .repetitiveOutput:
            return String.l10n("settings.localai.error.repetitiveOutput")
        case .memoryBudgetExceeded:
            return String.l10n("toolbar.localai.memoryBudgetExceeded")
        case .contextTooLong:
            return String.l10n("toolbar.localai.contextTooLong")
        case .repositoryChatInputTooLong:
            return String.l10n("ai.assistant.chat.contextBudget.inputTooLong")
        case .embeddingDimensionMismatch(let expected, let actual):
            return String(
                format: String.l10n("settings.localai.error.embeddingDimensionMismatchFormat"),
                expected, actual)
        }
    }
}
