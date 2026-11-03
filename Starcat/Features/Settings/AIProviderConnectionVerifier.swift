//
//  AIProviderConnectionVerifier.swift
//  Starcat
//
//  服务商连接验证的无持久化步骤。新增弹窗和既有配置重测共用同一模型发现规则，
//  验证期间不写 Keychain、AppSettings 或任务绑定；调用方确认会话仍有效后才保存。
//

import Foundation

/// 将待验证配置转换为已发现模型的配置快照，不负责保存或切换当前服务商。
@MainActor
enum AIProviderConnectionVerifier {
    /// 缓存只保存检测事实，不保存合并后的配置，避免命中缓存时覆盖用户刚修改的模型选项。
    struct Result: Equatable, Sendable {
        let models: [AIModelDescriptor]
        let baseURL: String
        let testedAt: String

        /// 每个调用方用自己的最新草稿合并目录，持久化权限仍由外层会话控制。
        func applying(to profile: AIProviderProfile, referencedModelNames: Set<String> = []) -> AIProviderProfile {
            var verified = profile
            verified.baseURL = baseURL
            verified.mergeDiscoveredModels(models, referencedModelNames: referencedModelNames)
            verified.isEnabled = true
            verified.lastTestedAt = testedAt
            verified.lastTestStatus = .success(modelCount: verified.models.count)
            return verified
        }
    }

    /// 新增、编辑和导入仍返回验证后的草稿；网络检测与自动/手动重测共用 probe。
    static func verify(
        profile: AIProviderProfile,
        apiKey: String,
        referencedModelNames: Set<String> = []
    ) async throws -> AIProviderProfile {
        let result = try await probe(configuration: configuration(profile: profile, apiKey: apiKey))
        return result.applying(to: profile, referencedModelNames: referencedModelNames)
    }

    /// 检测身份只包含实际请求输入，不因显示名、勾选或参数编辑反复发起请求。
    static func configuration(profile: AIProviderProfile, apiKey: String) -> AIClientConfiguration {
        AIClientConfiguration(
            providerID: profile.id,
            provider: profile.provider,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: profile.baseURL,
            chatModel: profile.models.first(where: { $0.capability == .chat })?.name
                ?? profile.provider.defaultChatModel,
            embeddingModel: profile.models.first(where: { $0.capability == .embedding })?.name
                ?? profile.provider.defaultEmbeddingModel,
            timeoutInterval: 60
        )
    }

    /// URLSession 异步等待网络，不同步阻塞主线程；模型发现和路径探测只维护这一份实现。
    static func probe(
        configuration: AIClientConfiguration,
        makeClient: (AIClientConfiguration) throws -> any AIClientProtocol = AIClientFactory.make
    ) async throws -> Result {
        try Task.checkCancellation()
        let client = try makeClient(configuration)
        let models = try await client.listModels()
        try Task.checkCancellation()

        return Result(
            models: models,
            baseURL: (client as? AnthropicClient)?.probedBaseURL ?? configuration.baseURL,
            testedAt: ISO8601DateFormatter.shared.string(from: Date())
        )
    }
}
