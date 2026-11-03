//
//  AIProviderSetupViewModelTests.swift
//  StarcatTests
//
//  新增与编辑服务商的提交边界：失败、取消及输入变化均不能保存迟到结果。
//  测试只注入内存验证与提交闭包，不访问网络、Keychain 或 AppSettings。
//

import Foundation
import Testing
@testable import Starcat

/// 验证弹窗会话只提交仍有效的成功快照。
@MainActor
@Suite("AIProviderSetupViewModel")
struct AIProviderSetupViewModelTests {
    @Test("验证成功后才提交，并使用同一次验证的凭据快照")
    func successCommitsVerifiedSnapshot() async {
        let recorder = AdditionRecorder()
        let viewModel = AIProviderSetupViewModel { profile, _ in
            Self.verified(profile)
        }
        viewModel.apiKey = "  test-key  "

        let added = await viewModel.testAndAdd(onAdd: recorder.add)

        #expect(added)
        #expect(recorder.profiles.count == 1)
        #expect(recorder.profiles.first?.isVerifiedConfiguration == true)
        #expect(recorder.apiKey == "test-key")
        #expect(!viewModel.isTesting)
        #expect(!viewModel.canTest)
        let repeated = await viewModel.testAndAdd(onAdd: recorder.add)
        #expect(!repeated)
        #expect(recorder.profiles.count == 1)
    }

    @Test("旧验证结束不能清掉新验证的等待状态")
    func oldAttemptDoesNotResetNewAttempt() async {
        let firstProbe = DeferredVerification()
        let secondProbe = DeferredVerification()
        let recorder = AdditionRecorder()
        var attempts = 0
        let viewModel = AIProviderSetupViewModel { profile, _ in
            attempts += 1
            return try await (attempts == 1 ? firstProbe : secondProbe).verify(profile)
        }
        viewModel.apiKey = "first-key"
        let first = Task { await viewModel.testAndAdd(onAdd: recorder.add) }
        await firstProbe.waitUntilStarted()

        viewModel.apiKey = "second-key"
        let second = Task { await viewModel.testAndAdd(onAdd: recorder.add) }
        await secondProbe.waitUntilStarted()
        firstProbe.succeed()
        let firstAdded = await first.value

        #expect(!firstAdded)
        #expect(viewModel.isTesting)
        #expect(recorder.profiles.isEmpty)
        secondProbe.succeed()
        let secondAdded = await second.value
        #expect(secondAdded)
        #expect(recorder.apiKey == "second-key")
        #expect(!viewModel.isTesting)
    }

    @Test("取消宿主等待任务也不能继续保存")
    func cancelledCallerDoesNotAdd() async {
        let probe = DeferredVerification()
        let recorder = AdditionRecorder()
        let viewModel = AIProviderSetupViewModel { profile, _ in
            try await probe.verify(profile)
        }
        viewModel.apiKey = "test-key"
        let task = Task { await viewModel.testAndAdd(onAdd: recorder.add) }
        await probe.waitUntilStarted()
        task.cancel()
        probe.succeed()

        let added = await task.value
        #expect(!added)
        #expect(recorder.profiles.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isTesting)
    }

    @Test("验证失败保留输入且不提交")
    func failedVerificationDoesNotAdd() async {
        let recorder = AdditionRecorder()
        let viewModel = AIProviderSetupViewModel { _, _ in
            throw SetupTestError.failed
        }
        viewModel.apiKey = "test-key"

        let added = await viewModel.testAndAdd(onAdd: recorder.add)

        #expect(!added)
        #expect(recorder.profiles.isEmpty)
        #expect(viewModel.apiKey == "test-key")
        #expect(viewModel.errorMessage != nil)
        #expect(!viewModel.isTesting)
    }

    @Test("提交失败不关闭弹窗并展示错误")
    func failedPersistenceDoesNotReportSuccess() async {
        let viewModel = AIProviderSetupViewModel { profile, _ in
            Self.verified(profile)
        }
        viewModel.apiKey = "test-key"

        let added = await viewModel.testAndAdd { _, _ in
            throw SetupTestError.failed
        }

        #expect(!added)
        #expect(viewModel.errorMessage != nil)
        #expect(!viewModel.isTesting)
    }

    @Test("取消或修改输入后，即使客户端忽略取消也不提交迟到结果", arguments: Invalidation.allCases)
    func invalidationRejectsLateSuccess(_ trigger: Invalidation) async {
        let probe = DeferredVerification()
        let recorder = AdditionRecorder()
        let viewModel = AIProviderSetupViewModel { profile, _ in
            try await probe.verify(profile)
        }
        viewModel.apiKey = "test-key"
        let task = Task { await viewModel.testAndAdd(onAdd: recorder.add) }
        await probe.waitUntilStarted()

        switch trigger {
        case .close: viewModel.cancel()
        case .provider: viewModel.selectProvider(.ollama)
        case .displayName: viewModel.displayName = "Changed"
        case .baseURL: viewModel.baseURL = "https://example.invalid/v1"
        case .apiKey: viewModel.apiKey = "changed-key"
        }
        probe.succeed()
        let added = await task.value

        #expect(!added)
        #expect(recorder.profiles.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isTesting)
    }

    @Test("Ollama 允许空 Key，而需要凭据的服务商仍不能测试")
    func optionalAPIKeyUsesProviderPolicy() {
        let viewModel = AIProviderSetupViewModel()
        #expect(!viewModel.canTest)
        viewModel.selectProvider(.ollama)
        #expect(viewModel.canTest)
        #expect(viewModel.profile.displayName == AIServiceProvider.ollama.defaultProfileName)
        #expect(viewModel.profile.baseURL == AIServiceProvider.ollama.defaultBaseURL)
        #expect(!AIServiceProvider.userSelectableCases.contains(.localAI))
    }

    @Test("编辑预填原配置、固定服务商，密钥不回显")
    func editingKeepsProfileIdentityAndProvider() {
        let original = Self.verified(AIProviderProfile(
            provider: .deepSeek, displayName: "My provider", baseURL: "https://example.invalid/v1"
        ))
        let viewModel = AIProviderSetupViewModel(editingProfile: original, existingAPIKey: "saved-key")

        #expect(viewModel.isEditing)
        #expect(viewModel.profile == original)
        #expect(viewModel.apiKey.isEmpty)
        #expect(viewModel.hasExistingAPIKey)
        #expect(viewModel.canTest)
        viewModel.selectProvider(.ollama)
        #expect(viewModel.profile == original)
    }

    @Test("编辑空密钥沿用原凭据，非空输入替换凭据", arguments: ["", "   ", "  new-key  "])
    func editingVerifiesEffectiveCredential(_ input: String) async {
        let original = Self.verified(AIProviderProfile(provider: .deepSeek))
        let recorder = AdditionRecorder()
        let expectedKey = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "saved-key" : "new-key"
        let viewModel = AIProviderSetupViewModel(
            editingProfile: original, existingAPIKey: "saved-key"
        ) { profile, key in
            #expect(profile.id == original.id)
            #expect(key == expectedKey)
            return Self.verified(profile)
        }
        viewModel.displayName = "Renamed"
        viewModel.apiKey = input

        let saved = await viewModel.testAndAdd(onAdd: recorder.add)

        #expect(saved)
        #expect(recorder.profiles.first?.id == original.id)
        #expect(recorder.profiles.first?.displayName == "Renamed")
        #expect(recorder.apiKey == expectedKey)
    }

    @Test("编辑已有配置验证失败时不覆盖原配置")
    func editingFailureDoesNotCommit() async {
        let original = Self.verified(AIProviderProfile(provider: .deepSeek))
        let recorder = AdditionRecorder()
        let viewModel = AIProviderSetupViewModel(
            editingProfile: original, existingAPIKey: "saved-key"
        ) { _, _ in
            throw SetupTestError.failed
        }
        viewModel.baseURL = "https://changed.invalid/v1"

        let saved = await viewModel.testAndAdd(onAdd: recorder.add)

        #expect(!saved)
        #expect(recorder.profiles.isEmpty)
        #expect(viewModel.baseURL == "https://changed.invalid/v1")
        #expect(viewModel.profile.lastTestStatus == original.lastTestStatus)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.canTest)
    }

    @Test("关闭编辑窗口后忽略迟到的验证成功")
    func cancelledEditDoesNotCommit() async {
        let probe = DeferredVerification()
        let recorder = AdditionRecorder()
        let viewModel = AIProviderSetupViewModel(
            editingProfile: Self.verified(AIProviderProfile(provider: .deepSeek)),
            existingAPIKey: "saved-key"
        ) { profile, _ in
            try await probe.verify(profile)
        }
        let task = Task { await viewModel.testAndAdd(onAdd: recorder.add) }
        await probe.waitUntilStarted()
        viewModel.cancel()
        probe.succeed()

        let saved = await task.value
        #expect(!saved)
        #expect(recorder.profiles.isEmpty)
    }

    /// 用于覆盖各种会话失效入口，而非依赖真实 URLSession 能否及时响应取消。
    enum Invalidation: CaseIterable, Sendable {
        case close, provider, displayName, baseURL, apiKey
    }

    private static func verified(_ profile: AIProviderProfile) -> AIProviderProfile {
        var verified = profile
        verified.isEnabled = true
        verified.lastTestStatus = .success(modelCount: 0)
        return verified
    }

    private enum SetupTestError: Error { case failed }

    /// 记录提交副作用，使失败与取消测试可以断言没有任何保存调用。
    @MainActor
    private final class AdditionRecorder {
        var profiles: [AIProviderProfile] = []
        var apiKey: String?

        func add(_ profile: AIProviderProfile, apiKey: String) {
            profiles.append(profile)
            self.apiKey = apiKey
        }
    }

    /// 故意不响应 Task.cancel，模拟网络适配器在取消后仍返回成功的最坏情况。
    @MainActor
    private final class DeferredVerification {
        private var profile: AIProviderProfile?
        private var result: CheckedContinuation<AIProviderProfile, Error>?
        private var started: CheckedContinuation<Void, Never>?

        func verify(_ profile: AIProviderProfile) async throws -> AIProviderProfile {
            self.profile = profile
            return try await withCheckedThrowingContinuation { continuation in
                result = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            guard result == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func succeed() {
            guard let profile, let result else {
                preconditionFailure("Verification must start before completion")
            }
            self.result = nil
            result.resume(returning: AIProviderSetupViewModelTests.verified(profile))
        }
    }
}
