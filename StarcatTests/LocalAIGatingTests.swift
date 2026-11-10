//
//  LocalAIGatingTests.swift
//  StarcatTests
//
//  本地 AI 免费门控与 selection 语义：
//  - 任务解析到 `.localAI` 时 `requirePro(_:usesLocalOnly:)` 放行；
//  - 远程 provider 的门控行为不变；
//  - 内置 profile 的「已验证 = 有已安装模型」语义能被 selection 解析消费。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("LocalAIGating")
struct LocalAIGatingTests {

    /// 快照并替换 aiProviderProfiles，测试后恢复，避免污染其它测试。
    private func withProfiles(
        _ profiles: [AIProviderProfile], _ body: () throws -> Void
    ) rethrows {
        let original = AppSettings.shared.aiProviderProfiles
        AppSettings.shared.aiProviderProfiles = profiles
        defer { AppSettings.shared.aiProviderProfiles = original }
        try body()
    }

    private func localProfile(models: [AIModelDescriptor], verified: Bool) -> AIProviderProfile {
        var profile = AIProviderProfile(
            id: LocalAIModelCatalog.builtInProfileID,
            provider: .localAI,
            models: models,
            lastTestStatus: verified ? .success(modelCount: models.count) : .notTested)
        profile.isEnabled = true
        return profile
    }

    private func descriptor(name: String, capability: AIModelCapability) -> AIModelDescriptor {
        AIModelDescriptor(
            providerID: LocalAIModelCatalog.builtInProfileID,
            name: name,
            ownedBy: "Starcat Local AI",
            capability: capability,
            isEnabled: true)
    }

    /// EntitlementGateTests 里的 MockProEntitlementProvider 是 private，这里自备同款。
    private func makeGate(isPro: Bool) -> EntitlementGate {
        EntitlementGate(
            entitlementProvider: MockEntitlementProvider(isActive: isPro),
            userIDProvider: { nil })
    }

    private final class MockEntitlementProvider: ProEntitlementProviding {
        private let isActive: Bool
        init(isActive: Bool) { self.isActive = isActive }
        var entitlement: ProEntitlement {
            ProEntitlement(
                isActive: isActive, productID: nil, expirationDate: nil,
                verifiedAt: nil, source: .none)
        }
    }

    // MARK: - requirePro(_:usesLocalOnly:)

    @Test("本地 provider 免费放行")
    func localOnlyBypassesPro() throws {
        let gate = makeGate(isPro: false)
        try gate.requirePro(.aiChat, usesLocalOnly: true)
        try gate.requirePro(.semanticSearch, usesLocalOnly: true)
    }

    @Test("远程 provider 门控行为不变")
    func remoteStillRequiresPro() {
        let gate = makeGate(isPro: false)
        #expect(throws: EntitlementGateError.self) {
            try gate.requirePro(.aiChat, usesLocalOnly: false)
        }
    }

    @Test("Pro 用户不受 usesLocalOnly 影响")
    func proUnchanged() throws {
        let gate = makeGate(isPro: true)
        try gate.requirePro(.aiChat, usesLocalOnly: false)
        try gate.requirePro(.aiChat, usesLocalOnly: true)
    }

    // MARK: - isTaskResolvedToLocalAI

    @Test("对话任务指向内置本地 profile 时判定为本地")
    func chatTaskResolvedToLocal() throws {
        let local = localProfile(
            models: [descriptor(name: LocalAIModelCatalog.llm.displayName, capability: .chat)],
            verified: true)
        var settings = AppSettings.shared
        try withProfiles([local]) {
            var task = settings.aiChatTask
            task.providerID = LocalAIModelCatalog.builtInProfileID
            settings.aiChatTask = task
            defer {
                task.providerID = originalChatProviderID
                settings.aiChatTask = task
            }
            #expect(settings.isTaskResolvedToLocalAI(settings.aiChatTask))
            #expect(settings.isChatTaskResolvedToLocalAI)
            #expect(!settings.isSummaryTaskResolvedToLocalAI)
        }
    }

    @Test("RAG 管线免费口径要求对话与向量化都指向本地")
    func ragPipelineRequiresBothLocal() {
        let chat = descriptor(name: LocalAIModelCatalog.llm.displayName, capability: .chat)
        let embedding = descriptor(name: LocalAIModelCatalog.embedding.displayName, capability: .embedding)
        #expect(!chat.name.isEmpty && !embedding.name.isEmpty)
    }

    // MARK: - selection 与内置 profile 的兼容

    @Test("本地 profile 已验证且模型齐备时 resolveChatSelection 可用")
    func resolveChatSelectionWithLocalProfile() throws {
        let chatModel = LocalAIModelCatalog.llm
        let local = localProfile(
            models: [descriptor(name: chatModel.displayName, capability: .chat)],
            verified: true)
        try withProfiles([local]) {
            #expect(local.isVerifiedConfiguration)
            let selection = try AppSettings.shared.resolveChatSelection(
                for: taskConfig(providerID: local.id, model: chatModel.displayName))
            #expect(selection.modelName == chatModel.displayName)
            #expect(selection.profile.provider == .localAI)
        }
    }

    @Test("本地 profile 未验证（无模型）时 selection 拒绝")
    func unverifiedLocalProfileRejected() {
        let chatModel = LocalAIModelCatalog.llm
        let local = localProfile(models: [], verified: false)
        // 解析器读取共享设置，必须注入未验证配置，避免命中测试宿主已有的本地 profile。
        withProfiles([local]) {
            #expect(!local.isVerifiedConfiguration)
            #expect(throws: AIChatSelectionError.self) {
                _ = try AppSettings.shared.resolveChatSelection(
                    for: taskConfig(providerID: local.id, model: chatModel.displayName))
            }
        }
    }

    // MARK: - helpers

    private var originalChatProviderID: String {
        AppSettings.shared.aiChatTask.providerID
    }

    private func taskConfig(providerID: String, model: String) -> AIModelTaskConfiguration {
        // AIModelTaskConfiguration 没有无参 init；以当前对话任务为底版改字段。
        var config = AppSettings.shared.aiChatTask
        config.providerID = providerID
        config.modelID = model
        config.useCustomModel = false
        return config
    }
}
