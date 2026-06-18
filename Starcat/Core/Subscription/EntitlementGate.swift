//
//  EntitlementGate.swift
//  Starcat
//
//  Pro 权益与免费限额门控。
//

import Foundation
import Observation

/// 需要 Pro 或受免费限额控制的功能。
///
/// 枚举放在 Core/Subscription，是为了让业务层只表达“我要使用哪个能力”，不关心
/// StoreKit、试用配额或数量上限的具体实现。
enum ProFeature: String, CaseIterable, Sendable {
    case aiSummary
    case aiTags
    case aiChat
    case batchAI
    case autoOrganize
    case readmeTranslation
    case semanticSearch
    case anySearchWeb
    case repoContext
    case releaseSubscription
    case tagCreation
    case cloudSync

    var title: String {
        switch self {
        case .aiSummary: return String.l10n("subscription.feature.aiSummary")
        case .aiTags: return String.l10n("subscription.feature.aiTags")
        case .aiChat: return String.l10n("subscription.feature.aiChat")
        case .batchAI: return String.l10n("subscription.feature.batchAI")
        case .autoOrganize: return String.l10n("subscription.feature.autoOrganize")
        case .readmeTranslation: return String.l10n("subscription.feature.readmeTranslation")
        case .semanticSearch: return String.l10n("subscription.feature.semanticSearch")
        case .anySearchWeb: return String.l10n("subscription.feature.anySearchWeb")
        case .repoContext: return String.l10n("subscription.feature.repoContext")
        case .releaseSubscription: return String.l10n("subscription.feature.releaseSubscription")
        case .tagCreation: return String.l10n("subscription.feature.tagCreation")
        case .cloudSync: return String.l10n("subscription.feature.cloudSync")
        }
    }

    var trialQuotaKind: TrialQuotaKind? {
        switch self {
        case .aiSummary: return .aiSummary
        case .aiTags: return .aiTags
        default: return nil
        }
    }
}

/// 门控失败原因。
enum EntitlementGateError: Error, LocalizedError, Equatable {
    case requiresPro(feature: ProFeature)
    case trialQuotaExceeded(feature: ProFeature, limit: Int)
    case tagLimitReached(limit: Int)
    case releaseSubscriptionLimitReached(limit: Int)

    var errorDescription: String? {
        switch self {
        case .requiresPro(let feature):
            return String(format: String.l10n("subscription.gate.requiresProFormat"), feature.title)
        case .trialQuotaExceeded(let feature, let limit):
            return String(format: String.l10n("subscription.gate.trialExceededFormat"), feature.title, limit)
        case .tagLimitReached(let limit):
            return String(format: String.l10n("subscription.gate.tagLimitFormat"), limit)
        case .releaseSubscriptionLimitReached(let limit):
            return String(format: String.l10n("subscription.gate.releaseLimitFormat"), limit)
        }
    }

    var feature: ProFeature {
        switch self {
        case .requiresPro(let feature), .trialQuotaExceeded(let feature, _):
            return feature
        case .tagLimitReached:
            return .tagCreation
        case .releaseSubscriptionLimitReached:
            return .releaseSubscription
        }
    }
}

/// 统一权益门控。
///
/// 业务层不要直接读取 `AppSettings.isProUser` 来判断是否放行；这样可以保证 StoreKit、
/// 试用配额、数量上限和后续 CloudKit Pro 门控都走同一条规则。
@MainActor
@Observable
final class EntitlementGate {
    static let freeTagLimit = 20
    static let freeReleaseSubscriptionLimit = 5

    private let entitlementProvider: any ProEntitlementProviding
    private let trialQuotaStore: TrialQuotaStore
    private let userIDProvider: @MainActor () -> Int64?

    init(
        entitlementProvider: any ProEntitlementProviding,
        trialQuotaStore: TrialQuotaStore = TrialQuotaStore(),
        userIDProvider: @escaping @MainActor () -> Int64?
    ) {
        self.entitlementProvider = entitlementProvider
        self.trialQuotaStore = trialQuotaStore
        self.userIDProvider = userIDProvider
    }

    var isProUser: Bool {
        entitlementProvider.entitlement.isActive
    }

    func remainingTrialCount(for feature: ProFeature) -> Int? {
        guard let kind = feature.trialQuotaKind else { return nil }
        return trialQuotaStore.remaining(kind: kind, userID: userIDProvider())
    }

    /// Pro-only 功能校验。
    func requirePro(_ feature: ProFeature) throws {
        guard !isProUser else { return }
        throw EntitlementGateError.requiresPro(feature: feature)
    }

    /// Pro 或免费试用功能校验，并在免费路径成功时消耗一次配额。
    func consumeTrialOrRequirePro(_ feature: ProFeature) throws {
        guard !isProUser else { return }
        guard let kind = feature.trialQuotaKind else {
            throw EntitlementGateError.requiresPro(feature: feature)
        }
        let userID = userIDProvider()
        guard trialQuotaStore.consume(kind: kind, userID: userID) else {
            throw EntitlementGateError.trialQuotaExceeded(feature: feature, limit: kind.limit)
        }
    }

    func validateTagCreation(currentTagCount: Int) throws {
        guard !isProUser, currentTagCount >= Self.freeTagLimit else { return }
        throw EntitlementGateError.tagLimitReached(limit: Self.freeTagLimit)
    }

    func validateReleaseSubscription(activeSubscriptionCount: Int, isAlreadySubscribed: Bool) throws {
        guard !isProUser, !isAlreadySubscribed, activeSubscriptionCount >= Self.freeReleaseSubscriptionLimit else { return }
        throw EntitlementGateError.releaseSubscriptionLimitReached(limit: Self.freeReleaseSubscriptionLimit)
    }
}
