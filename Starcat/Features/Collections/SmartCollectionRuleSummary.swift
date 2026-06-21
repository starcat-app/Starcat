//
//  SmartCollectionRuleSummary.swift
//  Starcat
//
//  用户智能集合规则摘要 + 统一 filter 评估。
//

import Foundation

/// 把 `SmartCollectionRule` 格式化为多行摘要（每行一个维度）。
enum SmartCollectionRuleSummary {

    struct Context: Sendable {
        var tagName: @Sendable (String) -> String

        static func from(tags: [Tag]) -> Context {
            let map = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
            return Context { id in
                map[id] ?? String(id.prefix(8))
            }
        }
    }

    static func lines(rule: SmartCollectionRule, context: Context) -> [String] {
        var result: [String] = [scopeLine(rule.scope, context: context)]
        if let query = trimmedQuery(rule.query) {
            result.append(searchLine(query: query, mode: rule.searchMode))
        }
        if !rule.selectedTagIDs.isEmpty {
            let names = rule.selectedTagIDs.map(context.tagName).joined(separator: String.l10n("smartCollections.rule.listSeparator"))
            result.append(String(format: String.l10n("smartCollections.rule.tagsAnyFormat"), names))
        }
        if let status = rule.status {
            result.append(String(format: String.l10n("smartCollections.rule.statusFormat"), status.localizedDisplayName))
        }
        appendAdvancedLines(rule: rule, to: &result)
        var toggles: [String] = []
        if rule.hideArchived {
            toggles.append(String.l10n("smartCollections.rule.hideArchived"))
        }
        if rule.hideForks {
            toggles.append(String.l10n("smartCollections.rule.hideForks"))
        }
        toggles.append(String(format: String.l10n("smartCollections.rule.sortFormat"), rule.sortOption.localizedTitle))
        if !toggles.isEmpty {
            result.append(toggles.joined(separator: String.l10n("smartCollections.rule.listSeparator")))
        }
        return result
    }

    static func compact(rule: SmartCollectionRule, context: Context) -> String {
        lines(rule: rule, context: context).joined(separator: String.l10n("smartCollections.rule.compactSeparator"))
    }

    private static func appendAdvancedLines(rule: SmartCollectionRule, to result: inout [String]) {
        if let min = rule.starsMin, let max = rule.starsMax {
            result.append(String(format: String.l10n("smartCollections.rule.starsRangeFormat"), min, max))
        } else if let min = rule.starsMin {
            result.append(String(format: String.l10n("smartCollections.rule.starsMinFormat"), min))
        } else if let max = rule.starsMax {
            result.append(String(format: String.l10n("smartCollections.rule.starsMaxFormat"), max))
        }
        if let days = rule.pushedWithinDays {
            result.append(String(format: String.l10n("smartCollections.rule.pushedWithinFormat"), days))
        }
        if let days = rule.pushedOlderThanDays {
            result.append(String(format: String.l10n("smartCollections.rule.pushedOlderFormat"), days))
        }
        if let min = rule.healthScoreMin, let max = rule.healthScoreMax {
            result.append(String(format: String.l10n("smartCollections.rule.healthRangeFormat"), min, max))
        } else if let min = rule.healthScoreMin {
            result.append(String(format: String.l10n("smartCollections.rule.healthMinFormat"), min))
        } else if let max = rule.healthScoreMax {
            result.append(String(format: String.l10n("smartCollections.rule.healthMaxFormat"), max))
        }
        if let requireLicense = rule.requireLicense {
            result.append(requireLicense
                ? String.l10n("smartCollections.rule.requireLicenseYes")
                : String.l10n("smartCollections.rule.requireLicenseNo"))
        }
        if let requireTopics = rule.requireTopics {
            result.append(requireTopics
                ? String.l10n("smartCollections.rule.requireTopicsYes")
                : String.l10n("smartCollections.rule.requireTopicsNo"))
        }
        if let requireNote = rule.requireNote {
            result.append(requireNote
                ? String.l10n("smartCollections.rule.requireNoteYes")
                : String.l10n("smartCollections.rule.requireNoteNo"))
        }
    }

    private static func trimmedQuery(_ query: String?) -> String? {
        guard let query else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func scopeLine(_ scope: SmartCollectionRule.Scope, context: Context) -> String {
        switch scope {
        case .allStars:
            return String.l10n("smartCollections.rule.scope.allStars")
        case .untagged:
            return String.l10n("smartCollections.rule.scope.untagged")
        case .language(let language):
            let name = language.map(LanguageDisplayName.shortened(for:)) ?? String.l10n("smartCollections.rule.scope.uncategorizedLanguage")
            return String(format: String.l10n("smartCollections.rule.scope.languageFormat"), name)
        case .tag(let id):
            return String(format: String.l10n("smartCollections.rule.scope.tagFormat"), context.tagName(id))
        }
    }

    private static func searchLine(query: String, mode: SmartSearchMode) -> String {
        let modeLabel: String
        switch mode {
        case .keyword:
            modeLabel = String.l10n("smartCollections.rule.search.keyword")
        case .semantic:
            modeLabel = String.l10n("smartCollections.rule.search.semantic")
        }
        return String(format: String.l10n("smartCollections.rule.searchFormat"), modeLabel, query)
    }
}

/// Smart Collections 规则 filter 所需的本地上下文。
struct SmartCollectionRuleFilterContext: Sendable {
    var statusMap: [Int64: RepoStatus]
    var repoTagsMap: [Int64: Set<String>]
    var healthSnapshots: [Int64: RepoHealthSnapshot]
    var repoIdsWithNotes: Set<Int64>
    var now: Date

    static let empty = SmartCollectionRuleFilterContext(
        statusMap: [:],
        repoTagsMap: [:],
        healthSnapshots: [:],
        repoIdsWithNotes: [],
        now: Date()
    )
}

/// 对 scope / 搜索之后的结果应用完整规则（Manage 筛选 + 高阶 predicate）。
enum SmartCollectionRuleFilter {

    static func apply(
        repos: [Repo],
        rule: SmartCollectionRule,
        context: SmartCollectionRuleFilterContext
    ) -> [Repo] {
        var view = repos
        if rule.hideArchived {
            view.removeAll { $0.isArchived }
        }
        if rule.hideForks {
            view.removeAll { $0.isFork }
        }
        if let status = rule.status {
            view.removeAll { repo in
                let actual = context.statusMap[repo.id] ?? .unread
                return actual != status
            }
        }
        let tagIDs = Set(rule.selectedTagIDs)
        if !tagIDs.isEmpty {
            view.removeAll { repo in
                let tagsOfRepo = context.repoTagsMap[repo.id] ?? []
                return tagsOfRepo.isDisjoint(with: tagIDs)
            }
        }
        if let min = rule.starsMin {
            view.removeAll { $0.starsCount < min }
        }
        if let max = rule.starsMax {
            view.removeAll { $0.starsCount > max }
        }
        if let days = rule.pushedWithinDays {
            view.removeAll { repo in
                guard let pushedAt = ISO8601DateFormatter.githubDate(from: repo.pushedAt) else {
                    return true
                }
                return context.now.timeIntervalSince(pushedAt) > Double(days) * 86_400
            }
        }
        if let days = rule.pushedOlderThanDays {
            view.removeAll { repo in
                guard let pushedAt = ISO8601DateFormatter.githubDate(from: repo.pushedAt) else {
                    return true
                }
                return context.now.timeIntervalSince(pushedAt) <= Double(days) * 86_400
            }
        }
        if let min = rule.healthScoreMin {
            view.removeAll { repo in
                guard let score = context.healthSnapshots[repo.id]?.overallScore else { return true }
                return score < Double(min)
            }
        }
        if let max = rule.healthScoreMax {
            view.removeAll { repo in
                guard let score = context.healthSnapshots[repo.id]?.overallScore else { return true }
                return score > Double(max)
            }
        }
        if let requireLicense = rule.requireLicense {
            view.removeAll { repo in
                let hasLicense = repo.license?.isEmpty == false
                return requireLicense ? !hasLicense : hasLicense
            }
        }
        if let requireTopics = rule.requireTopics {
            view.removeAll { repo in
                let hasTopics = !repo.topicsArray.isEmpty
                return requireTopics ? !hasTopics : hasTopics
            }
        }
        if let requireNote = rule.requireNote {
            view.removeAll { repo in
                let hasNote = context.repoIdsWithNotes.contains(repo.id)
                return requireNote ? !hasNote : hasNote
            }
        }
        return view
    }

    /// 旧签名：无 Health / 笔记上下文时的高阶字段会被保守跳过（仅 Manage 筛选生效）。
    static func apply(
        repos: [Repo],
        rule: SmartCollectionRule,
        statusMap: [Int64: RepoStatus],
        repoTagsMap: [Int64: Set<String>]
    ) -> [Repo] {
        apply(
            repos: repos,
            rule: rule,
            context: SmartCollectionRuleFilterContext(
                statusMap: statusMap,
                repoTagsMap: repoTagsMap,
                healthSnapshots: [:],
                repoIdsWithNotes: [],
                now: Date()
            )
        )
    }
}
