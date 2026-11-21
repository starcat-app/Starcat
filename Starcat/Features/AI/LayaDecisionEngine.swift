//
//  LayaDecisionEngine.swift
//  Starcat
//
//  Laya 本地 MLX 决策引擎与进程级 runtime 容器。
//
//  Runtime 持有共享模型读租约直到显式卸载，保证 App Store / Direct 两个进程中
//  任一方推理时，另一方不能删除 mmap 中的权重。引擎只做中立请求到 Laya 文本
//  prompt 的映射，不包含仓库候选筛选或产品阈值。
//

import Foundation
import MLX

actor LayaDecisionRuntimeStore {
    static let shared = LayaDecisionRuntimeStore()

    /// MLX actor 在 `await` 时仍会重入；这里复用 Local AI 的串行准入门，保证一次
    /// 加载/推理结束前，删除流程不能释放 mmap 权重对应的共享读锁。
    private let operationGate = LocalAIOperationGate()
    private var runtime: LayaMLXDecisionRuntime?
    private var loadedDirectory: URL?
    private var modelAccessLease: LocalAIModelAccessLease?
    /// 安装状态属于磁盘，resident 只描述当前进程中的 MLX 驻留状态。
    private var resident: LocalAIResidentModel?
    private var isMLXInitialized = false
    private var queuedCount = 0
    private var unloadRequested = false
    private var idleMonitor: Task<Void, Never>?
    private let budget = LocalAIMemoryPolicy.budget(
        physicalMemory: ProcessInfo.processInfo.physicalMemory
    )

    func preload(from directory: URL) async throws {
        let context = logContext(directory: directory, feature: "model.load")
        try await withAdmission(
            context: context,
            waitingMessage: "Waiting for Laya runtime admission.",
            admittedMessage: "Laya runtime admission acquired."
        ) {
            do {
                try await preloadWhileAdmitted(from: directory)
            } catch {
                LocalAILog.record(
                    "runtime.failed",
                    "Laya model loading ended without a usable runtime.",
                    level: error is CancellationError ? .info : .error,
                    fields: LocalAILogEvent.errorFields(error)
                )
                throw error
            }
        }
    }

    private func preloadWhileAdmitted(from directory: URL) async throws {
        let normalizedDirectory = directory.standardizedFileURL
        if runtime != nil, loadedDirectory == normalizedDirectory {
            resident?.lastUsed = .now
            resident?.phase = unloadRequested ? .unloading : .ready
            LocalAILog.record("model.reused", "Reusing the resident Laya decision model.")
            return
        }

        unloadLoadedModel(reason: "model_switch")
        guard LayaDecisionModelCatalog.multilingual.memoryRecommendation <= UInt64(budget) else {
            throw LocalAIError.memoryBudgetExceeded
        }
        configureMemoryIfNeeded()
        let loadStartedAt = ProcessInfo.processInfo.systemUptime
        let previousBytes = Memory.activeMemory
        resident = LocalAIResidentModel(directory: normalizedDirectory, phase: .loading)
        LocalAILog.record(
            "model.load.started",
            "Loading the Laya decision model.",
            fields: ["budgetBytes": String(budget)]
        )
        var pendingLease: LocalAIModelAccessLease?
        do {
            let lease = try await LocalAISharedModelCoordinator.shared.acquireModelRead(
                at: normalizedDirectory
            )
            pendingLease = lease
            let loaded = try await LayaMLXDecisionRuntime.load(from: normalizedDirectory)
            runtime = loaded
            loadedDirectory = normalizedDirectory
            modelAccessLease = lease
            pendingLease = nil
            resident?.loadedBytes = max(0, Memory.activeMemory - previousBytes)
            resident?.lastUsed = .now
            resident?.error = nil
            resident?.phase = unloadRequested ? .unloading : .ready
            startIdleMonitorIfNeeded()
            LocalAILog.record(
                "model.load.completed",
                "Laya decision model loaded successfully.",
                fields: [
                    "durationSeconds": LocalAILogEvent.seconds(
                        ProcessInfo.processInfo.systemUptime - loadStartedAt
                    ),
                    "loadedBytes": String(resident?.loadedBytes ?? 0),
                ]
            )
        } catch {
            pendingLease?.release()
            runtime = nil
            loadedDirectory = nil
            modelAccessLease = nil
            resident?.phase = .failed
            resident?.loadedBytes = 0
            resident?.error = error.localizedDescription
            LocalAILog.record(
                "model.load.failed",
                "Laya decision model failed to load.",
                level: error is CancellationError ? .info : .error,
                fields: LocalAILogEvent.errorFields(error)
            )
            throw error
        }
    }

    func evaluate(
        state: String,
        questions: [String: String],
        modelDirectory: URL
    ) async throws -> [String: LayaNoulPrediction] {
        let context = logContext(directory: modelDirectory, feature: "decision")
        return try await withAdmission(
            context: context,
            waitingMessage: "Waiting for Laya inference admission.",
            admittedMessage: "Laya inference admission acquired."
        ) {
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                try await preloadWhileAdmitted(from: modelDirectory)
                guard let runtime else { throw LayaMLXDecisionError.runtimeNotLoaded }
                resident?.phase = unloadRequested ? .unloading : .running
                LocalAILog.record(
                    "inference.started",
                    "Laya decision inference started.",
                    fields: ["questionCount": String(questions.count)]
                )
                let result = try await runtime.predictNoulBatch(
                    state: state,
                    questions: questions
                )
                resident?.lastUsed = .now
                resident?.phase = unloadRequested ? .unloading : .ready
                if isMLXInitialized { Memory.clearCache() }
                LocalAILog.record(
                    "inference.completed",
                    "Laya decision inference completed.",
                    fields: [
                        "durationSeconds": LocalAILogEvent.seconds(
                            ProcessInfo.processInfo.systemUptime - startedAt
                        ),
                        "questionCount": String(questions.count),
                    ]
                )
                return result
            } catch {
                if runtime != nil {
                    resident?.lastUsed = .now
                    resident?.phase = unloadRequested ? .unloading : .ready
                }
                if isMLXInitialized { Memory.clearCache() }
                LocalAILog.record(
                    "runtime.failed",
                    "Laya inference ended without a result.",
                    level: error is CancellationError ? .info : .error,
                    fields: LocalAILogEvent.errorFields(error)
                )
                throw error
            }
        }
    }

    /// 等当前加载/推理完整退出后才释放读锁；调用方随后才可取得写锁删除目录。
    func unload(reason: String) async throws {
        guard runtime != nil
                || modelAccessLease != nil
                || resident.map({ [.loading, .running, .ready].contains($0.phase) }) == true
        else { return }
        let directory = loadedDirectory ?? resident?.directory
        let context = directory.map { logContext(directory: $0, feature: "model.unload") }
        unloadRequested = true
        if runtime != nil { resident?.phase = .unloading }
        LocalAILog.record(
            "model.unload.requested",
            "Laya model unload requested; waiting for active work to exit.",
            context: context,
            fields: ["reason": reason]
        )
        do {
            try await operationGate.acquire()
        } catch {
            unloadRequested = false
            if runtime != nil { resident?.phase = .ready }
            throw error
        }
        unloadLoadedModel(reason: reason, context: context)
        unloadRequested = false
        await operationGate.release()
    }

    func snapshot() -> LayaDecisionRuntimeSnapshot {
        LayaDecisionRuntimeSnapshot(
            model: resident,
            isMLXInitialized: isMLXInitialized,
            queuedCount: queuedCount
        )
    }

    private func unloadLoadedModel(reason: String, context: LocalAILogContext? = nil) {
        guard runtime != nil || modelAccessLease != nil else { return }
        let previous = resident
        runtime = nil
        loadedDirectory = nil
        modelAccessLease?.release()
        modelAccessLease = nil
        resident?.phase = .unloaded
        resident?.loadedBytes = 0
        resident?.error = nil
        resident?.lastUsed = .now
        idleMonitor?.cancel()
        idleMonitor = nil
        if isMLXInitialized { Memory.clearCache() }
        if let previous, previous.phase != .unloaded {
            LocalAILog.record(
                "model.unloaded",
                "Laya decision model released from memory.",
                context: context,
                fields: ["reason": reason]
            )
        }
        AppLog.ai.debug("Laya runtime unloaded: \(reason, privacy: .public)")
    }

    /// 与通用 Local AI runtime 共用同一组 MLX 全局限制，不能让决策模型绕过内存预算。
    private func configureMemoryIfNeeded() {
        guard !isMLXInitialized else { return }
        isMLXInitialized = true
        Memory.cacheLimit = LocalAIMemoryPolicy.cacheBytes
        Memory.memoryLimit = budget
    }

    private func startIdleMonitorIfNeeded() {
        guard idleMonitor == nil else { return }
        idleMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.unloadIfIdle()
            }
        }
    }

    /// 状态面板声明“空闲 60 秒自动卸载”，Laya 必须遵守同一生命周期语义。
    private func unloadIfIdle() async {
        guard !unloadRequested,
              queuedCount == 0,
              resident?.phase == .ready,
              let lastUsed = resident?.lastUsed,
              Date.now.timeIntervalSince(lastUsed) >= LocalAIMemoryPolicy.idleSeconds
        else { return }
        do {
            try await unload(reason: "idle_timeout")
        } catch is CancellationError {
            // Monitor cancellation is normal during explicit unload or app shutdown.
        } catch {
            AppLog.ai.error(
                "Idle Laya unload failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func logContext(directory: URL, feature: String) -> LocalAILogContext {
        let descriptor = LayaDecisionModelCatalog.multilingual
        return LocalAILogContext(
            modelID: descriptor.id,
            modelName: descriptor.displayName,
            feature: feature,
            directory: directory
        )
    }

    /// 加载与推理必须共享同一 FIFO 准入边界；集中处理排队计数与 release，避免新增
    /// 日志路径后遗漏许可归还，导致后续卸载永久等待。
    private func withAdmission<T: Sendable>(
        context: LocalAILogContext,
        waitingMessage: String,
        admittedMessage: String,
        operation: () async throws -> T
    ) async throws -> T {
        try await LocalAILogContext.$current.withValue(context) {
            let queuedAt = ProcessInfo.processInfo.systemUptime
            queuedCount += 1
            LocalAILog.record(
                "queue.entered",
                waitingMessage,
                fields: ["queued": String(queuedCount)]
            )
            do {
                try await operationGate.acquire()
            } catch {
                queuedCount -= 1
                throw error
            }
            queuedCount -= 1
            LocalAILog.record(
                "queue.admitted",
                admittedMessage,
                fields: [
                    "waitSeconds": LocalAILogEvent.seconds(
                        ProcessInfo.processInfo.systemUptime - queuedAt
                    )
                ]
            )
            do {
                let result = try await operation()
                await operationGate.release()
                return result
            } catch {
                await operationGate.release()
                throw error
            }
        }
    }
}

@MainActor
final class LayaDecisionEngine: DecisionEngineProviding {
    let id: DecisionEngineID = .laya

    private let modelManager: LayaDecisionModelManager
    private let runtimeStore: LayaDecisionRuntimeStore

    init(
        modelManager: LayaDecisionModelManager = .shared,
        runtimeStore: LayaDecisionRuntimeStore = .shared
    ) {
        self.modelManager = modelManager
        self.runtimeStore = runtimeStore
    }

    var availability: DecisionEngineAvailability {
        modelManager.installedDirectoryURL == nil
            ? .unavailable(reason: "Laya multilingual model is not installed")
            : .available
    }

    func evaluate(_ request: DecisionEvaluationRequest) async throws -> DecisionEvaluationResponse {
        guard let directory = modelManager.installedDirectoryURL else {
            throw DecisionEngineError.engineUnavailable(
                .laya,
                reason: "Laya multilingual model is not installed"
            )
        }
        guard request.assets == nil, request.questions.values.allSatisfy({ $0.type == .noul }) else {
            throw DecisionInputError("Unsupported question or image for the selected Laya runtime")
        }
        let prompts = request.questions.mapValues(\.legacyNoulPrompt)
        let predictions = try await runtimeStore.evaluate(
            state: request.state.localPromptText,
            questions: prompts,
            modelDirectory: directory
        )
        let answers = predictions.mapValues {
            DecisionAnswer(type: "noul", noul: $0.trueProbability)
        }
        return DecisionEvaluationResponse(answers: answers)
    }
}
