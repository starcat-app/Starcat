//
//  ReadmeTranslationEngineAvailability.swift
//  Starcat
//
//  计算详情菜单 / 设置默认引擎里「当前可展示」的引擎列表。
//
//  规则（产品已确认）：未配置或不可用的引擎直接不出现，不要灰显。
//

import Foundation
#if canImport(Translation)
import Translation
#endif

/// 系统翻译可用性探测。单测可注入假实现，避免依赖真机语言包。
protocol SystemTranslationAvailabilityChecking: Sendable {
    /// 目标语种是否至少「可支持」（含尚未下载、需系统授权下载）。
    func isSupported(target: ReadmeTranslationLanguage) async -> Bool
}

/// 生产实现：查 Apple `LanguageAvailability`。
///
/// `status(from:to:)` 要求明确源语言；菜单只关心「目标语是否可译」，
/// 用英语作探针对齐 README 常见原文，避免把同语种对误判成可用。
struct AppleSystemTranslationAvailabilityChecker: SystemTranslationAvailabilityChecking {
    func isSupported(target: ReadmeTranslationLanguage) async -> Bool {
        #if canImport(Translation)
        let availability = LanguageAvailability()
        let targetLanguage = target.localeLanguage
        let probeSource = Locale.Language(identifier: "en")
        // 目标已是英语时换日语探针，否则 en→en 恒为 unsupported。
        let source = target.resolved() == .english
            ? Locale.Language(identifier: "ja")
            : probeSource
        let status = await availability.status(from: source, to: targetLanguage)
        switch status {
        case .installed, .supported:
            return true
        case .unsupported:
            return false
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }
}

enum ReadmeTranslationEngineAvailability {

    /// 当前可展示的引擎（顺序：系统 → AI，便于菜单稳定）。
    @MainActor
    static func availableEngines(
        targetLanguage: ReadmeTranslationLanguage,
        settings: AppSettings,
        keychain: any KeychainManaging,
        systemChecker: any SystemTranslationAvailabilityChecking = AppleSystemTranslationAvailabilityChecker()
    ) async -> [ReadmeTranslationEngine] {
        var result: [ReadmeTranslationEngine] = []
        if await systemChecker.isSupported(target: targetLanguage.resolved()) {
            result.append(.system)
        }
        if isAIConfigured(settings: settings, keychain: keychain) {
            result.append(.ai)
        }
        return result
    }

    /// 与 `ReadmeTranslationService.makeClient` 前置条件对齐：有翻译任务、Provider、非空 Key。
    @MainActor
    static func isAIConfigured(
        settings: AppSettings,
        keychain: any KeychainManaging
    ) -> Bool {
        let task = settings.aiTranslationTask
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == task.providerID })
        else { return false }
        let apiKey = (try? keychain.loadAIKey(forProvider: profile.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { return false }
        let model = task.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            let fallback = settings.aiChatModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return !fallback.isEmpty
        }
        return true
    }

    /// 若当前默认不在可用列表，回落到第一个可用项；全无则保持原值（由 UI 禁用主按钮）。
    static func resolvedDefault(
        current: ReadmeTranslationEngine,
        available: [ReadmeTranslationEngine]
    ) -> ReadmeTranslationEngine {
        if available.contains(current) { return current }
        return available.first ?? current
    }
}

extension ReadmeTranslationLanguage {
    /// Apple Translation 用的 `Locale.Language`。
    var localeLanguage: Locale.Language {
        Locale.Language(identifier: resolved().rawValue)
    }
}
