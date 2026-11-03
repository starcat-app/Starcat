//
//  AIProviderConnectionTest.swift
//  Starcat
//
//  模型设置页连接检测的会话级缓存与请求合并。只缓存检测事实，不写 Keychain、
//  AppSettings 或任务绑定；自动检测与手动测试复用同一个异步验证器。
//

import Foundation

/// 状态由 MainActor 串行管理，网络通过 async/await 挂起，不使用阻塞等待或后台同步锁。
@MainActor
final class AIProviderConnectionTest {
    typealias Result = AIProviderConnectionVerifier.Result
    typealias Probe = @MainActor (AIClientConfiguration) async throws -> Result

    /// 每个服务商只保留当前输入的一份记录，凭据只存在本次设置会话的内存中。
    private struct Entry {
        let configuration: AIClientConfiguration
        let id: UUID
        var task: Task<Result, Error>?
        var outcome: Swift.Result<Result, Error>?
        var completedAt: TimeInterval?
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var entries: [String: Entry] = [:]
    private let probe: Probe
    private let now: () -> TimeInterval
    private let cacheLifetime: TimeInterval = 30

    /// 时钟可注入，测试到期边界无需 sleep；生产使用单调时钟，不受系统时间调整影响。
    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        probe: @escaping Probe = { try await AIProviderConnectionVerifier.probe(configuration: $0) }
    ) {
        self.now = now
        self.probe = probe
    }

    /// 自动检测复用 30 秒内的成功或失败；手动测试绕过缓存，但仍合并相同输入的在途请求。
    func check(_ configuration: AIClientConfiguration, force: Bool = false) async throws -> Result {
        try Task.checkCancellation()
        let providerID = configuration.providerID
        if let entry = entries[providerID], entry.configuration == configuration {
            if let task = entry.task {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            }
            if !force, let completedAt = entry.completedAt, now() - completedAt < cacheLifetime,
               let outcome = entry.outcome {
                return try outcome.get()
            }
        }

        // 输入改变立即取消旧网络任务；旧任务即便忽略取消，也不能覆盖新配置的缓存。
        entries[providerID]?.task?.cancel()
        let id = UUID()
        let operation = probe
        let task = Task { @MainActor in
            do {
                let result = try await operation(configuration)
                // 某些客户端忽略取消并返回成功；页面退场或配置变化后仍必须拒绝该结果。
                try Task.checkCancellation()
                complete(providerID: providerID, id: id, outcome: .success(result))
                return result
            } catch {
                if Task.isCancelled || error is CancellationError {
                    // 取消不属于连接失败；清掉已结束的任务，后续重测才能重新发请求。
                    if entries[providerID]?.id == id { entries.removeValue(forKey: providerID) }
                    throw CancellationError()
                }
                // operation 会进入用户可见模板，必须使用已本地化的动作名，不能传内部代码标识。
                let failure = Failure(message: UserFacingError.map(
                    error, operation: String.l10n("settings.ai.provider.testButton")
                ).message)
                complete(providerID: providerID, id: id, outcome: .failure(failure))
                throw failure
            }
        }
        entries[providerID] = Entry(configuration: configuration, id: id, task: task)

        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    /// 新增/编辑/导入同样复用连接检测，再把结果合并到各自草稿，不让缓存带回旧勾选。
    func verify(
        profile: AIProviderProfile,
        apiKey: String,
        referencedModelNames: Set<String> = []
    ) async throws -> AIProviderProfile {
        let result = try await check(
            AIProviderConnectionVerifier.configuration(profile: profile, apiKey: apiKey),
            force: true
        )
        return result.applying(to: profile, referencedModelNames: referencedModelNames)
    }

    /// 离开页面/关闭窗口时取消真实网络任务并清空缓存；迟到结果不能重新填回记录。
    func cancelAll() {
        for entry in entries.values { entry.task?.cancel() }
        entries.removeAll()
    }

    /// 只允许仍属于本次输入的请求发布结果；取消不是连接失败，不进入失败缓存。
    private func complete(
        providerID: String,
        id: UUID,
        outcome: Swift.Result<Result, Error>
    ) {
        guard var entry = entries[providerID], entry.id == id else { return }
        entry.task = nil
        entry.outcome = outcome
        entry.completedAt = now()
        entries[providerID] = entry
    }
}
