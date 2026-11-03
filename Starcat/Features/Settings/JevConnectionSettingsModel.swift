//
//  JevConnectionSettingsModel.swift
//  Starcat
//
//  实验功能页的 Jev 配置与显式连接测试。编辑内容和连接路由分别保存，
//  原生连接失败只改变路由状态，不能替换模型编辑字段或覆盖用户的新输入。
//

import Foundation
import Observation

/// 设置页拥有此实例，切换到 Laya 时仍保留 Jev 草稿；测试不参与业务请求的自动重试。
@MainActor
@Observable
final class JevConnectionSettingsModel {
    enum TestState: Equatable {
        case idle
        case testing
        case succeeded(source: JevDecisionAccess.Source, elapsedMilliseconds: Int, noul: Double)
        case failed(String)
    }

    struct ProbeResult {
        let elapsedMilliseconds: Int
        let noul: Double
    }

    typealias Probe = @MainActor (JevDecisionAccess) async throws -> ProbeResult
    typealias ModelLoader = @MainActor (String) async throws -> [String]

    // 官方列表不保证枚举全部固定版本，始终保留这两个明确支持的版本。
    static let fixedModelIDs = ["jev-1.13.0", "jev-1.14.0"]
    private(set) var availableModelIDs = JevConnectionSettingsModel.fixedModelIDs
    private(set) var isLoadingModels = false
    private(set) var modelListFailed = false

    var draftAPIKey: String {
        didSet {
            guard oldValue != draftAPIKey else { return }
            invalidateTest()
            invalidateModelList()
            // 非空输入只作草稿；清空立即删除已存 Key，保持原设置页的凭据语义。
            if draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? keychain.deleteServiceAPIKey(forService: JevDecisionEngine.keychainServiceID)
                hasStoredNativeAPIKey = false
                settings.typesafeNativeKeyTestFailed = false
            }
        }
    }
    private(set) var hasStoredNativeAPIKey: Bool
    private(set) var testState: TestState = .idle
    private(set) var nativeFailureMessage: String?
    private(set) var openRouterFallback: JevDecisionAccess?

    private let settings: AppSettings
    private let keychain: any KeychainManaging
    private let probe: Probe
    private let modelLoader: ModelLoader
    private var testRevision = UUID()
    private var modelListRevision = UUID()

    /// 注入探测和 Keychain 供单测隔离；正式页面仍使用原来的 TypeSafeClient。
    init(
        settings: AppSettings,
        keychain: any KeychainManaging = KeychainManager.shared,
        modelLoader: ModelLoader? = nil,
        probe: Probe? = nil
    ) {
        self.settings = settings
        self.keychain = keychain
        self.probe = probe ?? Self.probeConnection
        self.modelLoader = modelLoader ?? { try await TypeSafeClient().listModels(apiKey: $0) }
        let stored = (try? keychain.loadServiceAPIKey(forService: JevDecisionEngine.keychainServiceID)) ?? ""
        draftAPIKey = stored
        hasStoredNativeAPIKey = !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasStoredNativeAPIKey { settings.typesafeNativeKeyTestFailed = false }
        openRouterFallback = JevDecisionEngine.resolveOpenRouterFallback(settings: settings, keychain: keychain)
    }

    /// 原生模型始终绑定同一字段，不受 OpenRouter 的固定模型或测试结果影响。
    var nativeModelID: String {
        get { settings.typesafeModelID }
        set {
            guard settings.typesafeModelID != newValue else { return }
            settings.typesafeModelID = newValue
            invalidateTest()
        }
    }

    var nativeCredentialIsUsable: Bool {
        hasStoredNativeAPIKey && !settings.typesafeNativeKeyTestFailed
    }

    var nativeConnectionFailed: Bool {
        settings.typesafeNativeKeyTestFailed
    }

    var hasUsableCredential: Bool {
        nativeCredentialIsUsable || openRouterFallback != nil
    }

    var isUsingOpenRouter: Bool {
        !nativeCredentialIsUsable && openRouterFallback != nil
    }

    var canTest: Bool {
        testState != .testing
            && (draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? openRouterFallback != nil : hasAvailableModelSelection)
    }

    var hasAvailableModelSelection: Bool {
        availableModelIDs.contains(nativeModelID)
    }

    /// Key 改变时清理其专属候选；旧请求的成功或失败都不能污染新 Key 的列表。
    private func invalidateModelList() {
        modelListRevision = UUID()
        availableModelIDs = Self.fixedModelIDs
        isLoadingModels = false
        modelListFailed = false
    }

    /// 仅更新下拉候选，不改模型选择、已存 Key、测试结果或原生/备用路由。
    func refreshModels() async {
        let key = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isLoadingModels else { return }
        let revision = UUID()
        modelListRevision = revision
        isLoadingModels = true
        modelListFailed = false
        defer {
            if modelListRevision == revision { isLoadingModels = false }
        }
        do {
            let models = try await modelLoader(key)
            guard revision == modelListRevision, !Task.isCancelled else { return }
            var seen = Set(Self.fixedModelIDs)
            availableModelIDs = Self.fixedModelIDs + models.compactMap { name in
                let id = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return !id.isEmpty && seen.insert(id).inserted ? id : nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard revision == modelListRevision, !Task.isCancelled else { return }
            // 临时刷新失败保留已有候选，固定版本从初始化起始终可选。
            modelListFailed = true
        }
    }

    /// 编辑或离开页面使旧请求失效；异步返回后不得写回过期 Key 或路由标记。
    func invalidateTest() {
        testRevision = UUID()
        testState = .idle
        nativeFailureMessage = nil
    }

    func refreshOpenRouterFallback() {
        let next = JevDecisionEngine.resolveOpenRouterFallback(settings: settings, keychain: keychain)
        guard next != openRouterFallback else { return }
        openRouterFallback = next
        invalidateTest()
    }

    /// 显式测试始终优先输入中的原生 Key，即使之前失败，也允许修正模型后重试。
    /// 只有这次用户发起的探测可以顺带测试备用连接，业务调用不复用此双探测逻辑。
    func testConnection() async {
        guard canTest else { return }
        let candidate = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelSnapshot = nativeModelID
        guard let access = JevDecisionEngine.resolveAccess(
            settings: settings, keychain: keychain, nativeAPIKeyOverride: candidate
        ) else { return }
        let fallback = openRouterFallback
        let revision = UUID()
        testRevision = revision
        testState = .testing
        nativeFailureMessage = nil

        do {
            let result = try await probe(access)
            guard isCurrent(revision, model: modelSnapshot) else { return }
            recordSuccess(access: access, result: result)
        } catch is CancellationError {
            if isCurrent(revision, model: modelSnapshot) { testState = .idle }
        } catch {
            guard isCurrent(revision, model: modelSnapshot) else { return }
            guard access.api == .typeSafe else {
                testState = .failed(error.localizedDescription)
                return
            }
            let nativeError = error.localizedDescription
            nativeFailureMessage = nativeError
            settings.typesafeNativeKeyTestFailed = true
            guard let fallback else {
                testState = .failed(nativeError)
                return
            }
            do {
                let result = try await probe(fallback)
                guard isCurrent(revision, model: modelSnapshot) else { return }
                recordSuccess(access: fallback, result: result)
            } catch is CancellationError {
                if isCurrent(revision, model: modelSnapshot) { testState = .idle }
            } catch {
                guard isCurrent(revision, model: modelSnapshot) else { return }
                testState = .failed(String(
                    format: String.l10n("settings.labs.typesafe.test.bothFailedFormat"),
                    nativeError, error.localizedDescription
                ))
            }
        }
    }

    private func isCurrent(_ revision: UUID, model: String) -> Bool {
        guard revision == testRevision else { return false }
        guard model == nativeModelID else {
            // 也防守从其他窗口直接改 AppSettings 的情况。
            invalidateTest()
            return false
        }
        return true
    }

    private func recordSuccess(access: JevDecisionAccess, result: ProbeResult) {
        if access.api == .typeSafe {
            try? keychain.storeServiceAPIKey(access.apiKey, forService: JevDecisionEngine.keychainServiceID)
            hasStoredNativeAPIKey = true
            settings.typesafeNativeKeyTestFailed = false
            nativeFailureMessage = nil
        }
        testState = .succeeded(
            source: access.source,
            elapsedMilliseconds: result.elapsedMilliseconds,
            noul: result.noul
        )
    }

    /// 和重构前一样发一次真实 Noul 决策，避免把“能连上服务器”误报成模型可用。
    private static func probeConnection(using access: JevDecisionAccess) async throws -> ProbeResult {
        let start = ContinuousClock.now
        let response = try await TypeSafeClient().evaluate(
            state: "Starcat is a native macOS application for managing GitHub stars.",
            model: access.modelID,
            questions: [
                "demo": .noul(
                    instructions: "Does this text describe a software product?",
                    criteria: nil
                )
            ],
            apiKey: access.apiKey,
            api: access.api,
            operation: .connectionTest
        )
        let elapsed = start.duration(to: .now)
        guard let noul = response.answers["demo"]?.noul, noul.isFinite else {
            throw NSError(
                domain: "Starcat.JevConnection", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String.l10n("settings.labs.typesafe.test.missingAnswer")]
            )
        }
        return ProbeResult(
            elapsedMilliseconds: Int(elapsed.components.seconds) * 1_000
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000),
            noul: noul
        )
    }
}
