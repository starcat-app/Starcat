//
//  ServiceConnectionSettingsModel.swift
//  Starcat
//
//  自建服务的单卡片草稿与连接测试。自动探测只读，显式操作通过验证后才提交 URL 和凭据。
//

import Foundation
import Observation

/// 每个服务独立管理草稿；用户编辑任意字段时，旧请求的成功与失败都会失效。
@MainActor
@Observable
final class ServiceConnectionSettingsModel {
    typealias Probe = @MainActor (ThirdPartyService, URL, String?) async -> HealthCheckOutcome
    typealias Save = @MainActor (URL?, String?) async throws -> Void

    var draftURL = "" {
        didSet { if oldValue != draftURL { test.invalidate() } }
    }
    var draftAPIKey = "" {
        didSet { if oldValue != draftAPIKey { test.invalidate() } }
    }
    let test = SettingsConnectionTest<HealthCheckOutcome>()
    private let service: ThirdPartyService
    private var isLoaded = false

    init(service: ThirdPartyService) {
        self.service = service
    }

    /// 页面重新出现时不覆盖用户的未保存输入。
    func load(url: String?, apiKey: String?) {
        guard !isLoaded else { return }
        isLoaded = true
        draftURL = url ?? ""
        draftAPIKey = apiKey ?? ""
    }

    /// 捕获 URL 与 Key 的同一份快照；不健康的响应不调用保存，避免失败覆盖可用配置。
    func testConnection(
        savesOnSuccess: Bool,
        retriesTransientError: Bool = false,
        probe: Probe,
        save: Save
    ) async {
        let customURL: URL?
        switch ThirdPartyService.validate(draftURL) {
        case .valid(let url): customURL = service.normalizedBaseURL(url)
        case .empty: customURL = nil
        case .invalid: return
        }
        let trimmedKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let customKey = trimmedKey.isEmpty ? nil : trimmedKey
        // 清空表示使用内置 Key，不能重新读出用户正在替换的旧自定义凭据。
        let probeKey = customKey ?? StarcatAPIKeyDefaults.productionKeyOrNil(for: service)
        await test.run {
            var outcome = await probe(service, customURL ?? service.productionURL, probeKey)
            if retriesTransientError, outcome.shouldRetryForAutomaticProbe, !Task.isCancelled {
                outcome = await probe(service, customURL ?? service.productionURL, probeKey)
            }
            if outcome.isCancelledProbe { throw CancellationError() }
            return outcome
        } save: { outcome in
            guard savesOnSuccess, outcome.isHealthy else { return }
            try await save(customURL, customKey)
        }
    }

    /// 重置不伪造连接成功；清除配置完成后由调用方重新探测内置服务。
    func reset(save: Save) async -> Bool {
        let succeeded = await test.reset {
            try await save(nil, nil)
        }
        guard succeeded else { return false }
        draftURL = ""
        draftAPIKey = ""
        return true
    }
}
