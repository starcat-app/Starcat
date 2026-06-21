//
//  SmartCollectionRuleValidation.swift
//  Starcat
//
//  规则编辑器内的冲突 / 矛盾提示（不阻断保存，仅帮助用户理解 AND 语义）。
//

import Foundation

enum SmartCollectionRuleValidation {

    /// 返回需展示在编辑器预览区的警告文案（已本地化）。
    static func warnings(for rule: SmartCollectionRule) -> [String] {
        var result: [String] = []

        appendRangeWarning(min: rule.starsMin, max: rule.starsMax, key: "smartCollections.editor.validation.starsRange", to: &result)
        appendRangeWarning(min: rule.forksMin, max: rule.forksMax, key: "smartCollections.editor.validation.forksRange", to: &result)
        appendRangeWarning(min: rule.watchersMin, max: rule.watchersMax, key: "smartCollections.editor.validation.watchersRange", to: &result)
        appendRangeWarning(min: rule.healthScoreMin, max: rule.healthScoreMax, key: "smartCollections.editor.validation.healthRange", to: &result)

        if rule.pushedWithinDays != nil && rule.pushedOlderThanDays != nil {
            result.append(String.l10n("smartCollections.editor.validation.pushedConflict"))
        }
        if rule.starredWithinDays != nil && rule.starredOlderThanDays != nil {
            result.append(String.l10n("smartCollections.editor.validation.starredConflict"))
        }
        if rule.updatedWithinDays != nil && rule.updatedOlderThanDays != nil {
            result.append(String.l10n("smartCollections.editor.validation.updatedConflict"))
        }
        if rule.createdWithinDays != nil && rule.createdOlderThanDays != nil {
            result.append(String.l10n("smartCollections.editor.validation.createdConflict"))
        }

        let selected = Set(rule.selectedTagIDs)
        let excluded = Set(rule.excludedTagIDs)
        if !selected.isDisjoint(with: excluded) {
            result.append(String.l10n("smartCollections.editor.validation.tagIncludeExcludeOverlap"))
        }

        return result
    }

    private static func appendRangeWarning(min: Int?, max: Int?, key: String, to result: inout [String]) {
        guard let min, let max, min > max else { return }
        result.append(String.l10n(key))
    }
}
