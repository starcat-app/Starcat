//
//  SmartCollectionRuleSummary.swift
//  Starcat
//
//  用户智能集合规则的人类可读摘要。Save / 编辑 Sheet、总览卡片、列表 subtitle 共用，
//  避免三处各自拼字符串导致文案漂移。
//

import Foundation

/// 把 `SmartCollectionRule` 格式化为多行摘要（每行一个维度）。
enum SmartCollectionRuleSummary {

    /// 标签 id → 显示名；缺失时回退 id 前缀。
    struct Context: Sendable {
        var tagName: @Sendable (String) -> String

        static func from(tags: [Tag]) -> Context {
            let map = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })
            return Context { id in
                map[id] ?? String(id.prefix(8))
            }
        }
    }

    /// 返回非空摘要行；顺序固定，便于用户扫读。
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

    /// 单行紧凑摘要（列表 subtitle 用）。
    static func compact(rule: SmartCollectionRule, context: Context) -> String {
        lines(rule: rule, context: context).joined(separator: String.l10n("smartCollections.rule.compactSeparator"))
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

/// 对 scope 查询结果应用规则内的 Manage 筛选（hide / status / tags）。
///
/// 搜索词在 `fetchRepos(matching:)` 阶段处理；这里只做与 `computeFilteredSorted` 一致的过滤。
enum SmartCollectionRuleFilter {

    static func apply(
        repos: [Repo],
        rule: SmartCollectionRule,
        statusMap: [Int64: RepoStatus],
        repoTagsMap: [Int64: Set<String>]
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
                let actual = statusMap[repo.id] ?? .unread
                return actual != status
            }
        }
        let tagIDs = Set(rule.selectedTagIDs)
        if !tagIDs.isEmpty {
            view.removeAll { repo in
                let tagsOfRepo = repoTagsMap[repo.id] ?? []
                return tagsOfRepo.isDisjoint(with: tagIDs)
            }
        }
        return view
    }
}
