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
            let formatKey = rule.tagMatchMode.summaryKey
            result.append(String(format: String.l10n(formatKey), names))
        }
        if !rule.excludedTagIDs.isEmpty {
            let names = rule.excludedTagIDs.map(context.tagName).joined(separator: String.l10n("smartCollections.rule.listSeparator"))
            result.append(String(format: String.l10n("smartCollections.rule.tagsExcludedFormat"), names))
        }
        if !rule.filterLanguages.isEmpty {
            let langs = rule.filterLanguages.map { lang in
                lang.isEmpty
                    ? String.l10n("smartCollections.rule.scope.uncategorizedLanguage")
                    : LanguageDisplayName.shortened(for: lang)
            }.joined(separator: String.l10n("smartCollections.rule.listSeparator"))
            result.append(String(format: String.l10n("smartCollections.rule.languagesFormat"), langs))
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
        if let days = rule.starredWithinDays {
            result.append(String(format: String.l10n("smartCollections.rule.starredWithinFormat"), days))
        }
        if let days = rule.starredOlderThanDays {
            result.append(String(format: String.l10n("smartCollections.rule.starredOlderFormat"), days))
        }
        if let min = rule.forksMin, let max = rule.forksMax {
            result.append(String(format: String.l10n("smartCollections.rule.forksRangeFormat"), min, max))
        } else if let min = rule.forksMin {
            result.append(String(format: String.l10n("smartCollections.rule.forksMinFormat"), min))
        } else if let max = rule.forksMax {
            result.append(String(format: String.l10n("smartCollections.rule.forksMaxFormat"), max))
        }
        if let min = rule.watchersMin, let max = rule.watchersMax {
            result.append(String(format: String.l10n("smartCollections.rule.watchersRangeFormat"), min, max))
        } else if let min = rule.watchersMin {
            result.append(String(format: String.l10n("smartCollections.rule.watchersMinFormat"), min))
        } else if let max = rule.watchersMax {
            result.append(String(format: String.l10n("smartCollections.rule.watchersMaxFormat"), max))
        }
        if let days = rule.updatedWithinDays {
            result.append(String(format: String.l10n("smartCollections.rule.updatedWithinFormat"), days))
        }
        if let days = rule.updatedOlderThanDays {
            result.append(String(format: String.l10n("smartCollections.rule.updatedOlderFormat"), days))
        }
        if let days = rule.createdWithinDays {
            result.append(String(format: String.l10n("smartCollections.rule.createdWithinFormat"), days))
        }
        if let days = rule.createdOlderThanDays {
            result.append(String(format: String.l10n("smartCollections.rule.createdOlderFormat"), days))
        }
        if let days = rule.releaseWithinDays {
            result.append(String(format: String.l10n("smartCollections.rule.releaseWithinFormat"), days))
        }
        if let min = rule.healthScoreMin, let max = rule.healthScoreMax {
            result.append(String(format: String.l10n("smartCollections.rule.healthRangeFormat"), min, max))
        } else if let min = rule.healthScoreMin {
            result.append(String(format: String.l10n("smartCollections.rule.healthMinFormat"), min))
        } else if let max = rule.healthScoreMax {
            result.append(String(format: String.l10n("smartCollections.rule.healthMaxFormat"), max))
        }
        if !rule.healthGrades.isEmpty {
            let grades = rule.healthGrades.sorted().joined(separator: String.l10n("smartCollections.rule.listSeparator"))
            result.append(String(format: String.l10n("smartCollections.rule.healthGradesFormat"), grades))
        }
        if let min = rule.maintenanceScoreMin {
            result.append(String(format: String.l10n("smartCollections.rule.maintenanceMinFormat"), min))
        }
        if let min = rule.popularityScoreMin {
            result.append(String(format: String.l10n("smartCollections.rule.popularityMinFormat"), min))
        }
        if let min = rule.qualityScoreMin {
            result.append(String(format: String.l10n("smartCollections.rule.qualityMinFormat"), min))
        }
        if let min = rule.securityScoreMin {
            result.append(String(format: String.l10n("smartCollections.rule.securityMinFormat"), min))
        }
        if let min = rule.openSSFScoreMin {
            result.append(String(format: String.l10n("smartCollections.rule.openSSFMinFormat"), min))
        }
        if let requireDescription = rule.requireDescription {
            result.append(requireDescription
                ? String.l10n("smartCollections.rule.requireDescriptionYes")
                : String.l10n("smartCollections.rule.requireDescriptionNo"))
        }
        if let requireHomepage = rule.requireHomepage {
            result.append(requireHomepage
                ? String.l10n("smartCollections.rule.requireHomepageYes")
                : String.l10n("smartCollections.rule.requireHomepageNo"))
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
        if let topic = trimmedQuery(rule.topicContains) {
            result.append(String(format: String.l10n("smartCollections.rule.topicContainsFormat"), topic))
        }
        if let min = rule.semanticScoreMin {
            result.append(String(format: String.l10n("smartCollections.rule.semanticMinFormat"), min))
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
    var openSSFScores: [Int64: Double]
    /// repo_id → 最新 release 的 published_at（ISO8601）。
    var latestReleasePublishedAt: [Int64: String]
    var semanticHitMap: [Int64: SemanticSearchHit]
    var now: Date

    static let empty = SmartCollectionRuleFilterContext(
        statusMap: [:],
        repoTagsMap: [:],
        healthSnapshots: [:],
        repoIdsWithNotes: [],
        openSSFScores: [:],
        latestReleasePublishedAt: [:],
        semanticHitMap: [:],
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
                switch rule.tagMatchMode {
                case .any:
                    return tagsOfRepo.isDisjoint(with: tagIDs)
                case .all:
                    return !tagIDs.isSubset(of: tagsOfRepo)
                }
            }
        }
        let excludedTagIDs = Set(rule.excludedTagIDs)
        if !excludedTagIDs.isEmpty {
            view.removeAll { repo in
                let tagsOfRepo = context.repoTagsMap[repo.id] ?? []
                return !tagsOfRepo.isDisjoint(with: excludedTagIDs)
            }
        }
        if !rule.filterLanguages.isEmpty {
            let langs = Set(rule.filterLanguages)
            view.removeAll { repo in
                guard let language = repo.language else { return true }
                return !langs.contains(language)
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
        applyWithinDays(rule.starredWithinDays, dateString: \.starredAt, repos: &view, context: context)
        applyOlderThanDays(rule.starredOlderThanDays, dateString: \.starredAt, repos: &view, context: context)
        applyWithinDays(rule.updatedWithinDays, dateString: \.updatedAt, repos: &view, context: context)
        applyOlderThanDays(rule.updatedOlderThanDays, dateString: \.updatedAt, repos: &view, context: context)
        applyWithinDays(rule.createdWithinDays, dateString: \.createdAt, repos: &view, context: context)
        applyOlderThanDays(rule.createdOlderThanDays, dateString: \.createdAt, repos: &view, context: context)
        if let min = rule.forksMin {
            view.removeAll { $0.forksCount < min }
        }
        if let max = rule.forksMax {
            view.removeAll { $0.forksCount > max }
        }
        if let min = rule.watchersMin {
            view.removeAll { $0.watchersCount < min }
        }
        if let max = rule.watchersMax {
            view.removeAll { $0.watchersCount > max }
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
        if !rule.healthGrades.isEmpty {
            let allowed = Set(rule.healthGrades)
            view.removeAll { repo in
                guard let grade = context.healthSnapshots[repo.id]?.grade else { return true }
                return !allowed.contains(grade)
            }
        }
        applyDimensionMin(rule.maintenanceScoreMin, keyPath: \.maintenanceScore, repos: &view, context: context)
        applyDimensionMin(rule.popularityScoreMin, keyPath: \.popularityScore, repos: &view, context: context)
        applyDimensionMin(rule.qualityScoreMin, keyPath: \.qualityScore, repos: &view, context: context)
        applyDimensionMin(rule.securityScoreMin, keyPath: \.securityScore, repos: &view, context: context)
        if let min = rule.openSSFScoreMin {
            view.removeAll { repo in
                guard let score = context.openSSFScores[repo.id] else { return true }
                return score < Double(min)
            }
        }
        if let days = rule.releaseWithinDays {
            view.removeAll { repo in
                guard let published = context.latestReleasePublishedAt[repo.id],
                      let date = ISO8601DateFormatter.githubDate(from: published) else {
                    return true
                }
                return context.now.timeIntervalSince(date) > Double(days) * 86_400
            }
        }
        if let requireDescription = rule.requireDescription {
            view.removeAll { repo in
                let hasDescription = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                return requireDescription ? !hasDescription : hasDescription
            }
        }
        if let requireHomepage = rule.requireHomepage {
            view.removeAll { repo in
                let hasHomepage = repo.homepage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                return requireHomepage ? !hasHomepage : hasHomepage
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
        if let topicQuery = rule.topicContains?.trimmingCharacters(in: .whitespacesAndNewlines), !topicQuery.isEmpty {
            view.removeAll { repo in
                !repo.topicsArray.contains { $0.localizedCaseInsensitiveContains(topicQuery) }
            }
        }
        if let requireNote = rule.requireNote {
            view.removeAll { repo in
                let hasNote = context.repoIdsWithNotes.contains(repo.id)
                return requireNote ? !hasNote : hasNote
            }
        }
        if let minPercent = rule.semanticScoreMin {
            let threshold = Double(minPercent) / 100.0
            view.removeAll { repo in
                let score = context.semanticHitMap[repo.id]?.displayScore ?? 0
                return score < threshold
            }
        }
        return view
    }

    private static func applyWithinDays(
        _ days: Int?,
        dateString: KeyPath<Repo, String?>,
        repos: inout [Repo],
        context: SmartCollectionRuleFilterContext
    ) {
        guard let days else { return }
        repos.removeAll { repo in
            guard let raw = repo[keyPath: dateString],
                  let date = ISO8601DateFormatter.githubDate(from: raw) else {
                return true
            }
            return context.now.timeIntervalSince(date) > Double(days) * 86_400
        }
    }

    private static func applyOlderThanDays(
        _ days: Int?,
        dateString: KeyPath<Repo, String?>,
        repos: inout [Repo],
        context: SmartCollectionRuleFilterContext
    ) {
        guard let days else { return }
        repos.removeAll { repo in
            guard let raw = repo[keyPath: dateString],
                  let date = ISO8601DateFormatter.githubDate(from: raw) else {
                return true
            }
            return context.now.timeIntervalSince(date) <= Double(days) * 86_400
        }
    }

    private static func applyDimensionMin(
        _ min: Int?,
        keyPath: KeyPath<RepoHealthSnapshot, Double>,
        repos: inout [Repo],
        context: SmartCollectionRuleFilterContext
    ) {
        guard let min else { return }
        repos.removeAll { repo in
            guard let snapshot = context.healthSnapshots[repo.id] else { return true }
            return snapshot[keyPath: keyPath] < Double(min)
        }
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
                openSSFScores: [:],
                latestReleasePublishedAt: [:],
                semanticHitMap: [:],
                now: Date()
            )
        )
    }
}
