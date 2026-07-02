//
//  SmartCollectionRule+Template.swift
//  Starcat
//
//  内置系统集合 → 用户规则模板（AND 语义下的最佳近似，非 1:1 复刻 OR 逻辑）。
//

import Foundation

extension SmartCollectionRule {

    /// 从内置集合 kind 生成可编辑模板。系统集合部分条件为 OR，模板只保留 AND 可表达子集。
    ///
    /// 用途：规则编辑器「从内置集合创建」时的初始草稿；**不是**内置集合详情面板的规则展示来源
    /// （展示走 `SmartCollectionSystemRuleSummary`，与 `matchesSmartCollection` 对齐）。
    static func template(for kind: SmartCollectionKind) -> SmartCollectionRule {
        var rule = baseline
        switch kind {
        case .library:
            break
        case .needsReview:
            rule.healthScoreMax = 59
            rule.requireLicense = false
            rule.requireTopics = false
            rule.hideArchived = false
        case .unmaintained:
            rule.pushedOlderThanDays = 365
            rule.hideArchived = false
        case .highValue:
            rule.starsMin = 1_000
            rule.healthScoreMin = 75
            rule.hideArchived = true
        case .noTags:
            rule.scope = .untagged
        case .using:
            rule.statusRaw = RepoStatus.using.rawValue
        case .recentlyActive:
            rule.pushedWithinDays = 30
        }
        return rule
    }

    static func defaultName(for kind: SmartCollectionKind) -> String {
        switch kind {
        case .library: return String.l10n("smartCollections.library.title")
        case .needsReview: return String.l10n("smartCollections.needsReview.title")
        case .unmaintained: return String.l10n("smartCollections.unmaintained.title")
        case .highValue: return String.l10n("smartCollections.highValue.title")
        case .noTags: return String.l10n("smartCollections.noTags.title")
        case .using: return String.l10n("smartCollections.using.title")
        case .recentlyActive: return String.l10n("smartCollections.recentlyActive.title")
        }
    }

    /// 编辑器 / 测试用的空规则基线。
    static var baseline: SmartCollectionRule {
        SmartCollectionRule(
            scope: .allStars,
            query: nil,
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: nil,
            selectedTagIDs: [],
            hideArchived: false,
            hideForks: false,
            sortRaw: RepoSortOption.starredAtDesc.rawValue
        )
    }
}
