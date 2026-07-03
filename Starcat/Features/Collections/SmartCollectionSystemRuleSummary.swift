//
//  SmartCollectionSystemRuleSummary.swift
//  Starcat
//
//  内置系统智能集合的规则摘要——与 `HomeViewModel.matchesSmartCollection` 的 OR/AND 语义对齐。
//
//  为什么不能复用 `SmartCollectionRule.template(for:)` + `SmartCollectionRuleSummary`：
//  - 模板面向用户自定义规则编辑器，全是 AND predicate；
//  - 系统集合（尤其 needsReview / unmaintained / highValue）在运行时走 OR 或分支逻辑；
//  - 把 template 逐条展示会误导成「必须同时满足无 Topics + 低健康分」——与真实筛选不一致。
//

import Foundation

/// 内置系统集合的可读规则行（详情面板规则区专用）。
enum SmartCollectionSystemRuleSummary {

    static func lines(for kind: SmartCollectionKind) -> [String] {
        var result = criteriaLines(for: kind)
        result.append(
            String(
                format: String.l10n("smartCollections.rule.sortFormat"),
                RepoSortOption.starredAtDesc.localizedTitle
            )
        )
        return result
    }

    private static func criteriaLines(for kind: SmartCollectionKind) -> [String] {
        switch kind {
        case .library:
            return [String.l10n("library.state.inLibrary")]

        case .outsideLibraryStars:
            return [
                String.l10n("smartCollections.systemRule.matchAll"),
                String.l10n("smartCollections.rule.scope.allStars"),
                String.l10n("smartCollections.systemRule.outsideLibraryStars.notInLibrary"),
            ]

        case .needsReview:
            return [
                String.l10n("smartCollections.systemRule.matchAny"),
                String.l10n("smartCollections.systemRule.needsReview.archived"),
                String.l10n("smartCollections.systemRule.needsReview.lowHealth"),
                String.l10n("smartCollections.systemRule.needsReview.noLicense"),
                String.l10n("smartCollections.systemRule.needsReview.noTopics"),
            ]

        case .unmaintained:
            return [
                String.l10n("smartCollections.systemRule.matchAny"),
                String.l10n("smartCollections.systemRule.unmaintained.archived"),
                String(format: String.l10n("smartCollections.rule.pushedOlderFormat"), 365),
            ]

        case .highValue:
            return [
                String.l10n("smartCollections.systemRule.matchAll"),
                String.l10n("smartCollections.systemRule.highValue.notArchived"),
                String.l10n("smartCollections.systemRule.matchAny"),
                String.l10n("smartCollections.systemRule.highValue.withHealth"),
                String.l10n("smartCollections.systemRule.highValue.withoutHealth"),
            ]

        case .noTags:
            return [String.l10n("smartCollections.rule.scope.untagged")]

        case .using:
            return [
                String(
                    format: String.l10n("smartCollections.rule.statusFormat"),
                    RepoStatus.using.localizedDisplayName
                )
            ]

        case .recentlyActive:
            return [String(format: String.l10n("smartCollections.rule.pushedWithinFormat"), 30)]
        }
    }
}
