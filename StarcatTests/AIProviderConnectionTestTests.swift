//
//  AIProviderConnectionTestTests.swift
//  StarcatTests
//
//  设置页服务商异步检测的回归测试：使用可控时钟与挂起请求验证缓存、请求复用及取消边界，
//  不访问真实网络、Keychain、AppSettings 或本地模型。
//

import Foundation
import Testing
@testable import Starcat

/// 验证检测事实只属于对应配置，后台完成不会覆盖当前界面或用户的模型选项。
@MainActor
@Suite("AI provider connection test", .timeLimit(.minutes(1)))
struct AIProviderConnectionTestTests {
    @Test("首次失败与缓存失败只显示本地化提示，不泄露内部操作标识", arguments: [false, true])
    func failureDoesNotExposeInternalOperation(wrapped: Bool) async throws {
        var calls = 0
        let test = AIProviderConnectionTest(probe: { _ in
            calls += 1
            if wrapped {
                throw AIClientError.networkUnavailable(detail: "Internal transport detail")
            }
            throw URLError(.cannotConnectToHost)
        })
        let state = SettingsConnectionTest<AIProviderConnectionVerifier.Result>()
        await state.run { try await test.check(Self.configuration()) }
        let firstMessage = try #require(state.errorMessage)
        #expect(!firstMessage.contains("ai.provider.connectionTest"))
        #expect(!firstMessage.contains("Internal transport detail"))
        #expect(firstMessage.contains(String.l10n("settings.ai.provider.testButton")))

        state.invalidate()
        await state.run { try await test.check(Self.configuration()) }
        #expect(state.errorMessage == firstMessage)
        #expect(calls == 1, "缓存复用的失败提示同样不能带回内部操作标识")
    }

    @Test("切换服务商后复用 30 秒内的成功和失败", arguments: [false, true])
    func switchingReusesRecentOutcome(fails: Bool) async throws {
        let clock = Clock()
        var calls = 0
        let test = AIProviderConnectionTest(now: { clock.time }) { configuration in
            calls += 1
            if fails && configuration.providerID == "A" { throw URLError(.cannotConnectToHost) }
            return Self.result(configuration)
        }
        let first = await outcome { try await test.check(Self.configuration("A")) }
        _ = try await test.check(Self.configuration("B"))
        clock.time = 29.99
        let cached = await outcome { try await test.check(Self.configuration("A")) }
        #expect(first == cached)
        #expect(calls == 2)
        clock.time = 30
        _ = await outcome { try await test.check(Self.configuration("A")) }
        #expect(calls == 3, "到期后必须重新检测，历史成功不代表服务仍在线")
    }

    @Test("缓存从请求完成时计时，手动测试绕过缓存")
    func expiryStartsAtCompletionAndManualTestForcesRetry() async throws {
        let clock = Clock()
        let probe = DeferredProbe()
        let test = AIProviderConnectionTest(now: { clock.time }, probe: probe.run)
        let configuration = Self.configuration()
        let first = Task { try await test.check(configuration) }
        await probe.waitForRequests(1)
        clock.time = 100
        probe.finish(0, with: .success(Self.result(configuration)))
        _ = try await first.value
        clock.time = 129
        _ = try await test.check(configuration)
        #expect(probe.requests.count == 1)

        let manual = Task { try await test.check(configuration, force: true) }
        await probe.waitForRequests(2)
        probe.finish(1, with: .success(Self.result(configuration)))
        _ = try await manual.value
        #expect(probe.requests.count == 2)
    }

    @Test("取消旧界面等待后，返回原服务商仍复用在途请求，手动测试也不重复发送")
    func returningToProviderJoinsInFlightRequest() async throws {
        let probe = DeferredProbe()
        let test = AIProviderConnectionTest(probe: probe.run)
        let configuration = Self.configuration("A")
        let first = Task { try await test.check(configuration) }
        await probe.waitForRequests(1)
        first.cancel()
        let other = Task { try await test.check(Self.configuration("B")) }
        await probe.waitForRequests(2)

        var joined = false
        let returning = Task {
            joined = true
            return try await test.check(configuration, force: true)
        }
        for _ in 0..<100 where !joined { await Task.yield() }
        try #require(joined)
        #expect(probe.requests.count == 2)
        probe.finish(0, with: .success(Self.result(configuration)))
        probe.finish(1, with: .success(Self.result(Self.configuration("B"))))
        #expect(await outcome { try await first.value } == .cancelled)
        #expect(try await returning.value == Self.result(configuration))
        _ = try await other.value
        #expect(!probe.cancelledRequests.contains(0), "切换只取消等待者，不能取消可复用的真实请求")
    }

    enum InputChange: CaseIterable, Sendable {
        case endpoint, credential, provider, chatModel, embeddingModel

        /// 每项都改变实际验证器的输入；与显示名或模型勾选等纯界面配置区分。
        func apply(to configuration: inout AIClientConfiguration) {
            switch self {
            case .endpoint: configuration.baseURL = "https://changed.invalid/v1"
            case .credential: configuration.apiKey = "changed-key"
            case .provider: configuration.provider = .anthropic
            case .chatModel: configuration.chatModel = "changed-chat"
            case .embeddingModel: configuration.embeddingModel = "changed-embedding"
            }
        }
    }

    @Test("请求输入变化立即失效缓存", arguments: InputChange.allCases)
    func changedConfigurationDoesNotReuseCache(_ change: InputChange) async throws {
        var calls = 0
        let test = AIProviderConnectionTest(probe: { configuration in
            calls += 1
            return Self.result(configuration)
        })
        var configuration = Self.configuration()
        _ = try await test.check(configuration)
        change.apply(to: &configuration)
        _ = try await test.check(configuration)
        #expect(calls == 2)
    }

    @Test("旧配置迟到成功或失败不能覆盖新配置缓存", arguments: [false, true])
    func lateOldConfigurationCannotReplaceNewOutcome(fails: Bool) async throws {
        let probe = DeferredProbe()
        let test = AIProviderConnectionTest(probe: probe.run)
        let oldConfiguration = Self.configuration()
        var nextConfiguration = oldConfiguration
        nextConfiguration.apiKey = "new-key"
        let old = Task { try await test.check(oldConfiguration) }
        await probe.waitForRequests(1)
        let next = Task { try await test.check(nextConfiguration) }
        await probe.waitForRequests(2)
        let expected = Self.result(nextConfiguration)
        probe.finish(1, with: .success(expected))
        _ = try await next.value
        probe.finish(0, with: fails ? .failure(URLError(.cannotConnectToHost))
            : .success(Self.result(oldConfiguration)))
        #expect(await outcome { try await old.value } == .cancelled)
        #expect(probe.cancelledRequests.contains(0))
        #expect(try await test.check(nextConfiguration) == expected)
        #expect(probe.requests.count == 2)
    }

    @Test("页面退场取消真实请求，迟到响应不能回填缓存", arguments: [false, true])
    func leavingPageCancelsAndClearsCache(fails: Bool) async throws {
        let probe = DeferredProbe()
        let test = AIProviderConnectionTest(probe: probe.run)
        let configuration = Self.configuration()
        let old = Task { try await test.check(configuration) }
        await probe.waitForRequests(1)
        test.cancelAll()
        let next = Task { try await test.check(configuration) }
        await probe.waitForRequests(2)
        probe.finish(0, with: fails ? .failure(URLError(.cannotConnectToHost))
            : .success(Self.result(configuration)))
        #expect(await outcome { try await old.value } == .cancelled)
        #expect(probe.cancelledRequests.contains(0))
        probe.finish(1, with: .success(Self.result(configuration)))
        _ = try await next.value
        _ = try await test.check(configuration)
        #expect(probe.requests.count == 2)
    }

    @Test("取消错误不缓存，后续检测可以重新开始")
    func cancellationIsNotCachedAsFailure() async throws {
        var calls = 0
        let test = AIProviderConnectionTest(probe: { configuration in
            calls += 1
            if calls == 1 { throw CancellationError() }
            return Self.result(configuration)
        })
        #expect(await outcome { try await test.check(Self.configuration()) } == .cancelled)
        _ = try await test.check(Self.configuration())
        #expect(calls == 2)
    }

    @Test("等待网络时 MainActor 可响应，旧服务商结果不影响当前检测状态")
    func asynchronousSwitchDoesNotPublishStaleStatus() async throws {
        let probe = DeferredProbe()
        let test = AIProviderConnectionTest(probe: probe.run)
        let state = SettingsConnectionTest<AIProviderConnectionVerifier.Result>()
        let first = Task {
            await state.run { try await test.check(Self.configuration("A")) }
        }
        await probe.waitForRequests(1)
        #expect(state.isTesting, "MainActor 在网络挂起期间仍能读取状态并切换服务商")
        first.cancel()
        state.invalidate()
        let next = Task {
            await state.run { try await test.check(Self.configuration("B")) }
        }
        await probe.waitForRequests(2)
        probe.finish(0, with: .success(Self.result(Self.configuration("A"))))
        await first.value
        #expect(state.isTesting)
        #expect(state.result == nil)
        probe.finish(1, with: .failure(URLError(.cannotConnectToHost)))
        await next.value
        #expect(!state.isTesting)
        #expect(state.result == nil)
        #expect(state.errorMessage != nil)
    }

    @Test("统一验证器只调用原有模型发现，不另发向量化请求")
    func verifierUsesExistingModelDiscovery() async throws {
        let configuration = Self.configuration()
        let expected = Self.result(configuration)
        let client = ModelListClient(models: expected.models)
        let result = try await AIProviderConnectionVerifier.probe(configuration: configuration) { input in
            #expect(input == configuration)
            return client
        }
        #expect(result.models == expected.models)
        #expect(result.baseURL == configuration.baseURL)
        #expect(await client.listCalls == 1)
    }

    @Test("编辑弹窗的测试与自动检测共用在途请求，成功后才提交草稿")
    func editingAndAutomaticCheckShareVerification() async throws {
        let probe = DeferredProbe()
        let test = AIProviderConnectionTest(probe: probe.run)
        let profile = AIProviderProfile(id: "A", provider: .openAICompatible, models: [
            AIModelDescriptor(providerID: "A", name: "chat", capability: .chat)
        ])
        let configuration = AIProviderConnectionVerifier.configuration(profile: profile, apiKey: "key")
        let automatic = Task { try await test.check(configuration) }
        await probe.waitForRequests(1)
        var joined = false
        var saved: AIProviderProfile?
        let editor = AIProviderSetupViewModel(editingProfile: profile, existingAPIKey: "key") { draft, key in
            joined = true
            return try await test.verify(profile: draft, apiKey: key)
        }
        let manual = Task {
            await editor.testAndAdd { verified, _ in saved = verified }
        }
        for _ in 0..<100 where !joined { await Task.yield() }
        try #require(joined)
        #expect(probe.requests.count == 1)
        #expect(saved == nil)
        probe.finish(0, with: .success(Self.result(configuration)))
        #expect(await manual.value)
        _ = try await automatic.value
        #expect(saved?.isVerifiedConfiguration == true)
        _ = try await test.check(configuration)
        #expect(probe.requests.count == 1)
    }

    @Test("缓存检测事实合并到最新草稿，不还原旧勾选或模型参数")
    func applyingResultPreservesLatestModelOptions() {
        let profile = AIProviderProfile(id: "A", provider: .openAICompatible, models: [
            AIModelDescriptor(providerID: "A", name: "chat", capability: .chat)
        ])
        let configuration = AIProviderConnectionVerifier.configuration(profile: profile, apiKey: "  key  ")
        var edited = profile
        edited.displayName = "Renamed"
        edited.models[0].isEnabled = false
        edited.models[0].parameters = .translationDefault
        #expect(AIProviderConnectionVerifier.configuration(profile: edited, apiKey: "key") == configuration)
        let result = Self.result(configuration)
        let merged = result.applying(to: edited)
        #expect(merged.displayName == "Renamed")
        #expect(merged.models.first(where: { $0.name == "chat" })?.isEnabled == false)
        #expect(merged.models.first(where: { $0.name == "chat" })?.parameters == .translationDefault)
    }

    /// 固定请求输入避免依赖真实服务商、系统默认模型或凭据。
    private static func configuration(_ id: String = "A") -> AIClientConfiguration {
        AIClientConfiguration(providerID: id, apiKey: "key", baseURL: "https://example.invalid/v1",
                              chatModel: "chat", embeddingModel: "embed", timeoutInterval: 60)
    }

    private static func result(_ configuration: AIClientConfiguration) -> AIProviderConnectionVerifier.Result {
        .init(models: [AIModelDescriptor(providerID: configuration.providerID, name: "chat")],
              baseURL: configuration.baseURL, testedAt: "2026-11-03T00:00:00Z")
    }

    private enum Outcome: Equatable {
        case success(AIProviderConnectionVerifier.Result), failure(String), cancelled
    }

    /// 将失败转换为可比较结果，以验证复用失败时保留相同的用户可见信息。
    private func outcome(
        _ operation: () async throws -> AIProviderConnectionVerifier.Result
    ) async -> Outcome {
        do { return .success(try await operation()) }
        catch is CancellationError { return .cancelled }
        catch { return .failure(error.localizedDescription) }
    }

    /// 可控的单调时钟，测试无需等待真实 30 秒。
    @MainActor
    private final class Clock {
        var time: TimeInterval = 0
    }

    /// 主动忽略取消的网络替身，证明隔离来自检测会话而非底层客户端恰好及时取消。
    @MainActor
    private final class DeferredProbe {
        private(set) var requests: [AIClientConfiguration] = []
        private(set) var cancelledRequests: Set<Int> = []
        private var pending: [Int: CheckedContinuation<AIProviderConnectionVerifier.Result, Error>] = [:]
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        /// 用 continuation 挂起，保留 MainActor 响应能力，不使用阻塞锁或 sleep。
        func run(_ configuration: AIClientConfiguration) async throws -> AIProviderConnectionVerifier.Result {
            let index = requests.count
            requests.append(configuration)
            defer { if Task.isCancelled { cancelledRequests.insert(index) } }
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                let ready = waiters.filter { $0.0 <= requests.count }
                waiters.removeAll { $0.0 <= requests.count }
                for (_, waiter) in ready { waiter.resume() }
            }
        }

        func waitForRequests(_ count: Int) async {
            guard requests.count < count else { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }

        func finish(_ index: Int, with result: Result<AIProviderConnectionVerifier.Result, Error>) {
            guard let continuation = pending.removeValue(forKey: index) else {
                preconditionFailure("Request must start before completion")
            }
            continuation.resume(with: result)
        }
    }

    /// 只有模型发现可被调用；任何额外生成或向量化请求都会使测试失败。
    private actor ModelListClient: AIClientProtocol {
        let models: [AIModelDescriptor]
        private(set) var listCalls = 0

        init(models: [AIModelDescriptor]) { self.models = models }

        func listModels() async throws -> [AIModelDescriptor] {
            listCalls += 1
            return models
        }

        func chat(request: AIChatRequest) async throws -> AIChatResponse { throw unexpectedCall() }
        func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
            throw unexpectedCall()
        }
        func embedding(input: String, model: String?) async throws -> [Float] { throw unexpectedCall() }
        func embeddings(inputs: [String], model: String?) async throws -> [[Float]] { throw unexpectedCall() }
        func testConnection() async throws { throw unexpectedCall() }
        nonisolated func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: unexpectedCall()) }
        }

        /// 出现额外调用即记录失败，避免仅凭最终模型列表正确而漏掉重复网络请求。
        nonisolated private func unexpectedCall() -> URLError {
            Issue.record("Connection verification must reuse listModels only")
            return URLError(.unsupportedURL)
        }
    }
}
