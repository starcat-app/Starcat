//
//  AIProviderSetupViewModel.swift
//  Starcat
//
//  新增与编辑服务商共用的独立草稿和验证生命周期。敏感输入只留在内存；验证完成不代表
//  允许保存，还必须确认弹窗、输入快照与任务均未失效，防止取消后迟到结果写入配置。
//

import Foundation
import Observation

/// 管理一次配置会话；持久化由同步提交回调完成，模型本身不接触 Keychain 或全局设置。
@MainActor
@Observable
final class AIProviderSetupViewModel: Identifiable {
    typealias Verification = @MainActor (AIProviderProfile, String) async throws -> AIProviderProfile
    typealias Addition = @MainActor (AIProviderProfile, String) throws -> Void

    let id = UUID()
    let isEditing: Bool
    private(set) var profile: AIProviderProfile
    private(set) var isTesting = false
    private(set) var errorMessage: String?
    private var apiKeyValue = ""
    /// 编辑时密钥只用于验证，不回填到输入框；空输入沿用原凭据。
    @ObservationIgnored private let existingAPIKey: String

    @ObservationIgnored private let verify: Verification
    @ObservationIgnored private var testingTask: Task<Bool, Never>?
    @ObservationIgnored private var attemptID: UUID?
    @ObservationIgnored private var isActive = true

    /// 验证闭包可注入，使取消和失败路径的测试不需要网络或真实凭据。
    init(
        provider: AIServiceProvider = .openAICompatible,
        editingProfile: AIProviderProfile? = nil,
        existingAPIKey: String = "",
        verify: @escaping Verification = { profile, apiKey in
            try await AIProviderConnectionVerifier.verify(profile: profile, apiKey: apiKey)
        }
    ) {
        let selectableProvider = AIServiceProvider.userSelectableCases.contains(provider)
            ? provider : .openAICompatible
        profile = editingProfile ?? AIProviderProfile(provider: selectableProvider, isEnabled: false)
        isEditing = editingProfile != nil
        self.existingAPIKey = editingProfile == nil ? "" : existingAPIKey
        self.verify = verify
    }

    var displayName: String {
        get { profile.displayName }
        set {
            guard profile.displayName != newValue else { return }
            invalidateAttempt()
            profile.displayName = newValue
        }
    }

    var baseURL: String {
        get { profile.baseURL }
        set {
            guard profile.baseURL != newValue else { return }
            invalidateAttempt()
            profile.baseURL = newValue
        }
    }

    var apiKey: String {
        get { apiKeyValue }
        set {
            guard apiKeyValue != newValue else { return }
            invalidateAttempt()
            apiKeyValue = newValue
        }
    }

    var canTest: Bool {
        isActive && !isTesting
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (profile.provider.allowsEmptyAPIKey
                || !effectiveAPIKey.isEmpty)
    }

    var hasExistingAPIKey: Bool {
        !existingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveAPIKey: String {
        let entered = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return entered.isEmpty && isEditing
            ? existingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) : entered
    }

    /// 切换类型会恢复该服务商的默认配置；内置 Local AI 不能在此重复创建。
    func selectProvider(_ provider: AIServiceProvider) {
        guard !isEditing, provider != profile.provider,
              AIServiceProvider.userSelectableCases.contains(provider) else { return }
        invalidateAttempt()
        profile = AIProviderProfile(provider: provider, isEnabled: false)
        apiKeyValue = ""
    }

    /// 只有验证与同步提交均成功才返回 true，供弹窗决定是否关闭。
    func testAndAdd(onAdd: @escaping Addition) async -> Bool {
        guard canTest, !Task.isCancelled else { return false }
        let id = UUID()
        let snapshot = profile
        let key = effectiveAPIKey
        attemptID = id
        isTesting = true
        errorMessage = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                // 旧请求晚于新请求结束时，不能清掉新请求的等待状态。
                if self.attemptID == id {
                    self.attemptID = nil
                    self.isTesting = false
                    self.testingTask = nil
                }
            }
            do {
                let verified = try await self.verify(snapshot, key)
                try Task.checkCancellation()
                guard self.isActive, self.attemptID == id else { return false }
                // 此处到提交返回之间没有 await，关闭或输入变化无法插入半次提交。
                try onAdd(verified, key)
                self.isActive = false
                return true
            } catch {
                guard self.isActive, self.attemptID == id, !Task.isCancelled,
                      !(error is CancellationError) else { return false }
                self.errorMessage = error.localizedDescription
                return false
            }
        }
        testingTask = task
        // 宿主调用任务被取消时，也取消实际验证任务，不能只停止等待却继续后台保存。
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 关闭弹窗时结束整个会话；即使底层客户端忽略取消，也无法再提交迟到结果。
    func cancel() {
        isActive = false
        invalidateAttempt()
    }

    /// 所有输入变更先失效旧快照，再允许下一次验证；失败不修改草稿输入。
    private func invalidateAttempt() {
        attemptID = nil
        testingTask?.cancel()
        testingTask = nil
        isTesting = false
        errorMessage = nil
    }
}
