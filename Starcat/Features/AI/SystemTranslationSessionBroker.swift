//
//  SystemTranslationSessionBroker.swift
//  Starcat
//
//  把 Apple TranslationSession 接到非 SwiftUI 的 README 翻译 Service。
//
//  为什么需要 Broker：
//  - macOS 15 上可靠拿到可下载语言包的 Session，必须走 SwiftUI `.translationTask`；
//  - `TranslationSession(installedSource:)` 要到更新的系统才可用，且要求语言已安装；
//  - Service / VM 不能直接持有 View，因此用 Configuration 触发 task，把 Session
//    交给等待中的续体连续完成一个 README 的多个 `translations(from:)` 批次。
//

import Foundation
import Observation
import SwiftUI
#if canImport(Translation)
@preconcurrency import Translation

// TranslationSession 不是 Sendable，但 Session 仅在 MainActor 宿主回调里使用。
extension TranslationSession: @unchecked @retroactive Sendable {}
#endif

/// 系统翻译请求失败。
enum SystemTranslationError: Error, LocalizedError, Equatable {
    case frameworkUnavailable
    case sessionUnavailable
    case emptyBatch
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return String.l10n("readme.translate.error.systemUnavailable")
        case .sessionUnavailable:
            return String.l10n("readme.translate.error.systemSession")
        case .emptyBatch:
            return String.l10n("readme.translate.error.emptySource")
        case .cancelled:
            return nil
        case .timedOut:
            // 复用已有系统翻译错误文案，避免在 String Catalog 中制造仅用于超时的重复文案。
            return String.l10n("readme.translate.error.systemSession")
        }
    }
}

/// App 根视图挂载的系统翻译会话桥。
@MainActor
@Observable
final class SystemTranslationSessionBroker {

    static let shared = SystemTranslationSessionBroker()

    /// 语言包下载或系统 Session 异常时不能让 README 永久停在 loading。
    private static let requestTimeoutNanoseconds: UInt64 = 60_000_000_000

    /// 非 nil 时触发 `.translationTask`；请求完成后保留，下一次同语言请求通过
    /// `Configuration.invalidate()` 重新触发 task，避免反复销毁和创建 TranslationSession。
    private(set) var configuration: TranslationSession.Configuration?

    /// 当前宿主正在消费的请求。保持一个 active request，避免多个 SwiftUI 宿主重复消费同一 Session。
    private var active: PendingRequest?
    /// 不同窗口同时请求翻译时排队，不再让后一个请求无条件取消前一个请求。
    private var queued: [PendingRequest] = []

    /// 同一个 App 可能同时存在主窗口和多个 AppKit 详情窗口，但 Apple Translation
    /// 的 `.translationTask` 不能让多个宿主同时持有同一份 Configuration。宿主注册后
    /// 只给第一个存活宿主返回配置，其余宿主保持 nil；当前宿主消失时再把所有权转移给
    /// 下一个宿主。这样既保留详情窗口在主窗口关闭后的翻译能力，也不会创建重复 Session。
    private var registeredHostIDs: [UUID] = []
    private var activeHostID: UUID?

    /// 每次激活请求都递增。SwiftUI 可能在旧 `.translationTask` 回调结束前送达新回调，
    /// generation 让旧 Session 无法误消费当前请求。
    private var nextGeneration: UInt64 = 0

    typealias BatchHandler = @MainActor (
        _ responses: [TranslationSession.Response],
        _ batchIndex: Int
    ) async throws -> Void

    /// 队列只保存 Sendable 的原文快照；TranslationSession.Request 必须在消费 Session 时即时构造。
    /// 这样不会把主 actor 上创建的 Request 实例跨到 Translation framework 的非隔离 API。
    private struct BatchItem: Sendable {
        let sourceHash: String
        let text: String
    }

    private final class PendingRequest {
        let id: UUID
        var generation: UInt64
        let source: Locale.Language
        let target: Locale.Language
        let batches: [[BatchItem]]
        let onBatch: BatchHandler?
        var continuation: CheckedContinuation<[[TranslationSession.Response]], Error>?
        var isConsuming = false
        var isCompleted = false

        init(
            id: UUID,
            generation: UInt64,
            source: Locale.Language,
            target: Locale.Language,
            batches: [[BatchItem]],
            onBatch: BatchHandler?,
            continuation: CheckedContinuation<[[TranslationSession.Response]], Error>? = nil
        ) {
            self.id = id
            self.generation = generation
            self.source = source
            self.target = target
            self.batches = batches
            self.onBatch = onBatch
            self.continuation = continuation
        }

        func finish(_ result: Result<[[TranslationSession.Response]], Error>) {
            guard !isCompleted else { return }
            isCompleted = true
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    /// 用一个系统 Session 连续翻译多个同语种批次。
    ///
    /// `onBatch` 在每批完成后回调，让上层继续增量写缓存和渲染；Session 本身只创建一次，
    /// 避免 README 每个批次都重新触发语言包准备。`clientIdentifier` 仍由上层用 sourceHash 回填。
    @discardableResult
    func translateBatches(
        batches: [[(sourceHash: String, text: String)]],
        sourceLanguage: ReadmeTranslationLanguage,
        targetLanguage: ReadmeTranslationLanguage,
        onBatch: BatchHandler? = nil
    ) async throws -> [[TranslationSession.Response]] {
        #if canImport(Translation)
        guard !batches.isEmpty, batches.allSatisfy({ !$0.isEmpty }) else {
            throw SystemTranslationError.emptyBatch
        }

        let requestID = UUID()
        return try await withThrowingTaskGroup(of: [[TranslationSession.Response]].self) { group in
            group.addTask { [weak self] in
                guard let self else { throw SystemTranslationError.sessionUnavailable }
                return try await self.enqueueAndWait(
                    requestID: requestID,
                    batches: batches,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    onBatch: onBatch
                )
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: Self.requestTimeoutNanoseconds)
                await self?.timeout(requestID: requestID)
                throw SystemTranslationError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw SystemTranslationError.sessionUnavailable
            }
            return result
        }
        #else
        throw SystemTranslationError.frameworkUnavailable
        #endif
    }

    /// 兼容单批调用方；新代码应优先使用 `translateBatches` 复用同一 Session。
    func translateBatch(
        items: [(sourceHash: String, text: String)],
        sourceLanguage: ReadmeTranslationLanguage,
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> [TranslationSession.Response] {
        #if canImport(Translation)
        let result = try await translateBatches(
            batches: [items],
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        guard let first = result.first else {
            throw SystemTranslationError.sessionUnavailable
        }
        return first
        #else
        throw SystemTranslationError.frameworkUnavailable
        #endif
    }

    /// 由根视图 `.translationTask` 回调；完成当前 active 后切换到排队请求。
    ///
    /// `hostID` 和 `generation` 必须同时匹配，避免主窗口 / 详情窗口的旧回调在
    /// 新请求已经激活后误消费新的 Configuration。
    func consumeSession(
        _ session: TranslationSession,
        hostID: UUID,
        generation: UInt64
    ) async {
        #if canImport(Translation)
        // 超时或取消可能已经把 continuation 结束；不要让稍后才抵达的 stale Session 再次触发系统翻译。
        guard activeHostID == hostID,
              let request = active,
              request.generation == generation,
              !request.isConsuming,
              !request.isCompleted
        else { return }
        request.isConsuming = true
        AppLog.ai.info(
            "System translation session started request=\(request.id.uuidString, privacy: .public) batches=\(request.batches.count, privacy: .public)"
        )
        do {
            let requestBatches = request.batches
            var allResponses: [[TranslationSession.Response]] = []

            // 先准备语言包，再进入正文批量翻译。已安装时该调用会快速返回；未安装时，
            // 系统在这里处理下载/授权，避免把资源准备时间伪装成「翻译卡住」。
            AppLog.ai.debug(
                "System translation preparing resources request=\(request.id.uuidString, privacy: .public)"
            )
            try await session.prepareTranslation()
            if #available(macOS 26.0, *), !(await session.isReady) {
                throw SystemTranslationError.sessionUnavailable
            }
            AppLog.ai.info(
                "System translation resources ready request=\(request.id.uuidString, privacy: .public)"
            )

            for (batchIndex, batch) in requestBatches.enumerated() {
                if request.isCompleted { break }
                guard !batch.isEmpty else {
                    throw SystemTranslationError.emptyBatch
                }
                let requests = Self.makeRequests(from: batch)
                AppLog.ai.debug(
                    "System translation batch started request=\(request.id.uuidString, privacy: .public) index=\(batchIndex + 1, privacy: .public)/\(requestBatches.count, privacy: .public) inputs=\(requests.count, privacy: .public)"
                )
                let responses = try await session.translations(from: requests)
                allResponses.append(responses)
                try await request.onBatch?(responses, batchIndex)
                AppLog.ai.debug(
                    "System translation batch completed request=\(request.id.uuidString, privacy: .public) index=\(batchIndex + 1, privacy: .public)/\(requestBatches.count, privacy: .public)"
                )
            }
            request.finish(.success(allResponses))
        } catch {
            if !request.isCompleted {
                // Translation framework 的底层错误可能不是 LocalizedError，必须归一到
                // 系统翻译错误，否则上层会误显示成 AI 服务失败。
                let userFacingError: Error = error is TranslationError
                    ? SystemTranslationError.sessionUnavailable
                    : error
                AppLog.ai.error(
                    "System translation failed request=\(request.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                request.finish(.failure(userFacingError))
            }
        }
        finishActive(request)
        #endif
    }

    #if canImport(Translation)
    private func enqueueAndWait(
        requestID: UUID,
        batches: [[(sourceHash: String, text: String)]],
        sourceLanguage: ReadmeTranslationLanguage,
        targetLanguage: ReadmeTranslationLanguage,
        onBatch: BatchHandler?
    ) async throws -> [[TranslationSession.Response]] {
        let target = targetLanguage.localeLanguage
        let source = sourceLanguage.localeLanguage
        let items = batches.map { batch in
            batch.map { BatchItem(sourceHash: $0.sourceHash, text: $0.text) }
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: SystemTranslationError.cancelled)
                    return
                }

                let request = PendingRequest(
                    id: requestID,
                    generation: nextGeneration,
                    source: source,
                    target: target,
                    batches: items,
                    onBatch: onBatch,
                    continuation: continuation
                )
                if active == nil {
                    activate(request)
                } else {
                    queued.append(request)
                    AppLog.ai.debug(
                        "System translation queued request=\(requestID.uuidString, privacy: .public) queue=\(self.queued.count, privacy: .public)"
                    )
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        })
    }

    private func activate(_ request: PendingRequest) {
        nextGeneration &+= 1
        request.generation = nextGeneration
        active = request
        // 首次配置显式传入源语言，避免 prepareTranslation() 因无法识别 source 而失败。
        // 同一语言对再次激活时才 invalidate，确保 SwiftUI 重新执行 translationTask。
        var config = TranslationSession.Configuration(source: request.source, target: request.target)
        if lastActivatedSource == request.source, lastActivatedTarget == request.target {
            config.invalidate()
        }
        lastActivatedSource = request.source
        lastActivatedTarget = request.target
        configuration = config
    }

    private func cancel(requestID: UUID) {
        if let active, active.id == requestID {
            // 无论 Session 是否已经进入 Translation framework，都要立刻释放 active。
            // 否则底层调用卡住时，后续请求会永久排在队列里，直到重启 App 才恢复。
            failActive(active, error: SystemTranslationError.cancelled)
            return
        }

        guard let index = queued.firstIndex(where: { $0.id == requestID }) else { return }
        let request = queued.remove(at: index)
        request.finish(.failure(SystemTranslationError.cancelled))
    }

    /// 超时与取消走同一条清理路径，但保留超时错误，让调用方能区分系统会话不可用。
    private func timeout(requestID: UUID) {
        if let active, active.id == requestID {
            failActive(active, error: SystemTranslationError.timedOut)
            return
        }

        guard let index = queued.firstIndex(where: { $0.id == requestID }) else { return }
        let request = queued.remove(at: index)
        request.finish(.failure(SystemTranslationError.timedOut))
    }

    private func failActive(_ request: PendingRequest, error: Error) {
        request.finish(.failure(error))
        // 先标记完成再结束 active；任何迟到的旧 callback 都会被
        // request.generation / request.isCompleted 双重拦截，Configuration 继续保留供下次复用。
        finishActive(request)
    }

    private func finishActive(_ request: PendingRequest) {
        guard active?.id == request.id else { return }
        active = nil
        // 不要把 Configuration 置 nil：SwiftUI 会先销毁旧 translationTask，再创建下一份
        // TranslationSession，连续打开多个 README 时容易与系统会话释放产生竞态。Apple
        // 官方要求同一语言对的新内容通过 invalidate() 重跑，这里保留配置正是为了复用该路径。
        guard !queued.isEmpty else { return }

        let next = queued.removeFirst()
        activate(next)
    }

    /// 在非隔离上下文生成 framework 请求，避免把主 actor 创建的 Request 作为参数送出。
    nonisolated private static func makeRequests(from batch: [BatchItem]) -> [TranslationSession.Request] {
        batch.map {
            TranslationSession.Request(
                sourceText: $0.text,
                clientIdentifier: $0.sourceHash
            )
        }
    }

    private var lastActivatedSource: Locale.Language?
    private var lastActivatedTarget: Locale.Language?
    #endif

    // MARK: - Translation host ownership

    /// 注册一个存活的 SwiftUI Translation 宿主。注册顺序决定当前 owner，保证
    /// 主窗口与详情窗口同时存在时只有一个宿主真正收到 Configuration。
    func registerHost(_ hostID: UUID) {
        guard !registeredHostIDs.contains(hostID) else { return }
        registeredHostIDs.append(hostID)
        if activeHostID == nil {
            activeHostID = hostID
        }
    }

    /// 宿主销毁时释放所有权。若它正在消费请求，先结束请求再切换到下一个宿主，
    /// 不让旧 Session 在新的窗口里继续写入结果。
    func unregisterHost(_ hostID: UUID) {
        registeredHostIDs.removeAll { $0 == hostID }
        guard activeHostID == hostID else { return }

        if let active {
            failActive(active, error: SystemTranslationError.sessionUnavailable)
        }
        activeHostID = registeredHostIDs.first
    }

    /// SwiftUI 宿主根据这个快照决定是否拿到 Configuration。generation 与配置一起
    /// 捕获到 `.translationTask` 闭包中，旧闭包即使迟到也不会消费新请求。
    #if canImport(Translation)
    struct HostActivation {
        let configuration: TranslationSession.Configuration?
        let generation: UInt64?
    }

    func activation(for hostID: UUID) -> HostActivation {
        guard activeHostID == hostID else {
            return HostActivation(configuration: nil, generation: nil)
        }
        return HostActivation(
            configuration: configuration,
            generation: active?.generation
        )
    }
    #endif

    // Internal read-only state used by the regression suite. Keeping the state on the
    // MainActor mirrors the real host lifecycle and avoids exposing mutable internals.
    var registeredHostCountForTesting: Int { registeredHostIDs.count }
    var activeHostIDForTesting: UUID? { activeHostID }

    #if DEBUG
    /// 用于验证连续 README 请求不会因为完成第一个请求而清空 Configuration。
    func activateSyntheticRequestForTesting(
        sourceLanguage: ReadmeTranslationLanguage,
        targetLanguage: ReadmeTranslationLanguage
    ) {
        let request = PendingRequest(
            id: UUID(),
            generation: nextGeneration,
            source: sourceLanguage.localeLanguage,
            target: targetLanguage.localeLanguage,
            batches: [],
            onBatch: nil
        )
        activate(request)
    }

    /// 仅结束测试请求，复用真实的 active 清理路径。
    func finishActiveForTesting() {
        guard let active else { return }
        finishActive(active)
    }
    #endif
}

/// 挂在 App 根上的零尺寸宿主，专门喂 `translationTask`。
///
/// 主窗口和 AppKit 详情窗口都可以挂载本 View，但 Broker 只会给一个宿主返回
/// Configuration，避免 Apple Translation 为同一请求创建多个竞争 Session。
struct SystemTranslationSessionHost: View {
    @Bindable var broker: SystemTranslationSessionBroker
    @State private var hostID = UUID()

    var body: some View {
        #if canImport(Translation)
        let activation = broker.activation(for: hostID)
        #endif
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                broker.registerHost(hostID)
            }
            .onDisappear {
                broker.unregisterHost(hostID)
            }
            #if canImport(Translation)
            .translationTask(activation.configuration) { session in
                guard let generation = activation.generation else { return }
                await broker.consumeSession(
                    session,
                    hostID: hostID,
                    generation: generation
                )
            }
            #endif
    }
}
