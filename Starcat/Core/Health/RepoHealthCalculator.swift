//
//  RepoHealthCalculator.swift
//  Starcat
//
//  Repo Health 确定性评分器。
//
//  第一版刻意只使用已有缓存：repos、releases、OpenSSF。
//  这样后台计算可以低成本批量跑，详情页也不会因为打开一个 repo 就同步触发
//  多个 GitHub API。后续要引入 issue 响应速度 / PR 数 / commit 频率时，应先
//  增加独立缓存表，再把新证据接入本评分器。
//

import Foundation

enum RepoHealthCalculator {
    static let snapshotTTL: TimeInterval = 24 * 60 * 60

    static func makeSnapshot(
        repo: Repo,
        latestRelease: ReleaseRecord?,
        openSSF: OpenSSFScoreRecord?,
        now: Date = Date()
    ) -> RepoHealthSnapshot {
        let maintenance = maintenanceScore(repo: repo, latestRelease: latestRelease, now: now)
        let popularity = popularityScore(repo: repo)
        let quality = qualityScore(repo: repo)
        let security = securityScore(openSSF: openSSF)

        let overall = clamp(
            maintenance.score * 0.35
            + popularity.score * 0.20
            + quality.score * 0.20
            + security.score * 0.25
        )
        let status: RepoHealthFetchStatus = security.facts.contains(where: { $0.tone == .missing && $0.key == "openSSF" })
            ? .partial
            : .success
        let generatedAt = ISO8601DateFormatter.shared.string(from: now)
        let payload = RepoHealthPayload(
            generatedAt: generatedAt,
            repoFullName: repo.fullName,
            dimensions: [maintenance, popularity, quality, security],
            latestReleaseTag: latestRelease?.tagName,
            latestReleasePublishedAt: latestRelease?.publishedAt,
            latestReleaseUrl: latestRelease?.htmlUrl,
            openSSFScore: openSSF?.aggregateScore,
            notes: status == .partial ? ["OpenSSF score is missing or not indexed."] : []
        )
        let payloadJSON = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"

        return RepoHealthSnapshot(
            repoId: repo.id,
            overallScore: overall,
            grade: grade(for: overall),
            maintenanceScore: maintenance.score,
            popularityScore: popularity.score,
            qualityScore: quality.score,
            securityScore: security.score,
            payloadJSON: payloadJSON,
            computedAt: generatedAt,
            staleAfter: ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(snapshotTTL)),
            fetchStatus: status,
            lastError: nil
        )
    }

    // MARK: - Dimension scorers

    private static func maintenanceScore(repo: Repo, latestRelease: ReleaseRecord?, now: Date) -> RepoHealthDimensionScore {
        var score = 50.0
        var facts: [RepoHealthFact] = []

        if repo.isArchived {
            score -= 45
            facts.append(fact(
                key: "archived",
                labelKey: "repoHealth.fact.archived.label",
                valueKey: "repoHealth.fact.archived.yes",
                tone: .bad
            ))
        } else {
            facts.append(fact(
                key: "archived",
                labelKey: "repoHealth.fact.archived.label",
                valueKey: "repoHealth.fact.archived.no",
                tone: .good
            ))
        }

        if let pushedAt = ISO8601DateFormatter.githubDate(from: repo.pushedAt) {
            let days = Int(now.timeIntervalSince(pushedAt) / 86_400)
            switch days {
            case ..<30:
                score += 30
                facts.append(fact(
                    key: "pushedAt",
                    labelKey: "repoHealth.fact.pushedAt.label",
                    valueKey: "repoHealth.fact.daysAgo.format",
                    valueArgs: ["\(days)"],
                    tone: .good
                ))
            case ..<180:
                score += 15
                facts.append(fact(
                    key: "pushedAt",
                    labelKey: "repoHealth.fact.pushedAt.label",
                    valueKey: "repoHealth.fact.daysAgo.format",
                    valueArgs: ["\(days)"],
                    tone: .neutral
                ))
            case ..<365:
                score -= 5
                facts.append(fact(
                    key: "pushedAt",
                    labelKey: "repoHealth.fact.pushedAt.label",
                    valueKey: "repoHealth.fact.daysAgo.format",
                    valueArgs: ["\(days)"],
                    tone: .bad
                ))
            default:
                score -= 20
                facts.append(fact(
                    key: "pushedAt",
                    labelKey: "repoHealth.fact.pushedAt.label",
                    valueKey: "repoHealth.fact.daysAgo.format",
                    valueArgs: ["\(days)"],
                    tone: .bad
                ))
            }
        } else {
            facts.append(missingFact(key: "pushedAt", labelKey: "repoHealth.fact.pushedAt.label"))
        }

        if let releaseDate = ISO8601DateFormatter.githubDate(from: latestRelease?.publishedAt)
            ?? ISO8601DateFormatter.githubDate(from: latestRelease?.createdAtRemote) {
            let days = Int(now.timeIntervalSince(releaseDate) / 86_400)
            let releaseTone: RepoHealthFactTone = days < 180 ? .good : (days > 365 ? .bad : .neutral)
            if days < 180 { score += 15 } else if days > 365 { score -= 10 }

            if let tag = latestRelease?.tagName, !tag.isEmpty {
                facts.append(fact(
                    key: "release",
                    labelKey: "repoHealth.fact.release.label",
                    valueKey: "repoHealth.fact.release.detail.format",
                    valueArgs: [tag, "\(days)"],
                    tone: releaseTone
                ))
            } else {
                facts.append(fact(
                    key: "release",
                    labelKey: "repoHealth.fact.release.label",
                    valueKey: "repoHealth.fact.release.daysOnly.format",
                    valueArgs: ["\(days)"],
                    tone: releaseTone
                ))
            }
        } else if let tag = latestRelease?.tagName, !tag.isEmpty {
            // 有 tag 但 published_at 不可解析(或草稿态)——仍展示 tag,不标「未知」。
            facts.append(fact(
                key: "release",
                labelKey: "repoHealth.fact.release.label",
                valueKey: "repoHealth.fact.release.tagOnly.format",
                valueArgs: [tag],
                tone: .neutral
            ))
        } else {
            facts.append(missingFact(key: "release", labelKey: "repoHealth.fact.release.label"))
        }

        return RepoHealthDimensionScore(
            dimension: .maintenance,
            score: clamp(score),
            summaryKey: "repoHealth.dimension.maintenance",
            facts: facts
        )
    }

    private static func popularityScore(repo: Repo) -> RepoHealthDimensionScore {
        let starScore = min(60, log10(Double(max(repo.starsCount, 1))) * 15)
        let forkScore = min(25, log10(Double(max(repo.forksCount, 1))) * 8)
        let watcherScore = min(15, log10(Double(max(repo.watchersCount, 1))) * 5)
        return RepoHealthDimensionScore(
            dimension: .popularity,
            score: clamp(starScore + forkScore + watcherScore),
            summaryKey: "repoHealth.dimension.popularity",
            facts: [
                fact(
                    key: "stars",
                    labelKey: "repoHealth.fact.stars.label",
                    valueKey: "repoHealth.fact.count.format",
                    valueArgs: ["\(repo.starsCount)"],
                    tone: .neutral
                ),
                fact(
                    key: "forks",
                    labelKey: "repoHealth.fact.forks.label",
                    valueKey: "repoHealth.fact.count.format",
                    valueArgs: ["\(repo.forksCount)"],
                    tone: .neutral
                ),
                fact(
                    key: "watchers",
                    labelKey: "repoHealth.fact.watchers.label",
                    valueKey: "repoHealth.fact.count.format",
                    valueArgs: ["\(repo.watchersCount)"],
                    tone: .neutral
                ),
            ]
        )
    }

    private static func qualityScore(repo: Repo) -> RepoHealthDimensionScore {
        var score = 35.0
        var facts: [RepoHealthFact] = []

        if let license = repo.license, !license.isEmpty {
            score += 15
            facts.append(fact(
                key: "license",
                labelKey: "repoHealth.fact.license.label",
                valueKey: "repoHealth.fact.license.value.format",
                valueArgs: [license],
                tone: .good
            ))
        } else {
            facts.append(missingFact(key: "license", labelKey: "repoHealth.fact.license.label"))
        }

        if !repo.topicsArray.isEmpty {
            score += 15
            facts.append(fact(
                key: "topics",
                labelKey: "repoHealth.fact.topics.label",
                valueKey: "repoHealth.fact.topics.count.format",
                valueArgs: ["\(repo.topicsArray.count)"],
                tone: .good
            ))
        } else {
            facts.append(fact(
                key: "topics",
                labelKey: "repoHealth.fact.topics.label",
                valueKey: "repoHealth.fact.topics.none",
                tone: .bad
            ))
        }

        if let homepage = repo.homepage, !homepage.isEmpty {
            score += 10
            let link = Self.normalizedHTTPURL(homepage)
            let display = URL(string: link)?.host ?? homepage
            facts.append(fact(
                key: "homepage",
                labelKey: "repoHealth.fact.homepage.label",
                valueKey: "repoHealth.fact.homepage.link.format",
                valueArgs: [display],
                tone: .good,
                linkURL: link
            ))
        } else {
            facts.append(fact(
                key: "homepage",
                labelKey: "repoHealth.fact.homepage.label",
                valueKey: "repoHealth.fact.homepage.no",
                tone: .neutral
            ))
        }

        // 不展示 defaultBranch(dong4j 2026-06-21);open PR 数本地缓存暂无独立字段,
        // GitHub `/repos` 只给含 PR 的 open_issues_count,不在此混淆展示。

        if let openIssues = repo.openIssuesCount {
            if openIssues <= 20 {
                score += 10
                facts.append(fact(
                    key: "openIssues",
                    labelKey: "repoHealth.fact.openIssues.label",
                    valueKey: "repoHealth.fact.count.format",
                    valueArgs: ["\(openIssues)"],
                    tone: .good
                ))
            } else if openIssues > 500 {
                score -= 10
                facts.append(fact(
                    key: "openIssues",
                    labelKey: "repoHealth.fact.openIssues.label",
                    valueKey: "repoHealth.fact.count.format",
                    valueArgs: ["\(openIssues)"],
                    tone: .bad
                ))
            } else {
                facts.append(fact(
                    key: "openIssues",
                    labelKey: "repoHealth.fact.openIssues.label",
                    valueKey: "repoHealth.fact.count.format",
                    valueArgs: ["\(openIssues)"],
                    tone: .neutral
                ))
            }
        } else {
            facts.append(missingFact(key: "openIssues", labelKey: "repoHealth.fact.openIssues.label"))
        }

        return RepoHealthDimensionScore(
            dimension: .quality,
            score: clamp(score),
            summaryKey: "repoHealth.dimension.quality",
            facts: facts
        )
    }

    private static func securityScore(openSSF: OpenSSFScoreRecord?) -> RepoHealthDimensionScore {
        guard let openSSF, openSSF.fetchStatus == .success, let aggregate = openSSF.aggregateScore else {
            return RepoHealthDimensionScore(
                dimension: .security,
                score: 50,
                summaryKey: "repoHealth.dimension.security",
                facts: [missingFact(key: "openSSF", labelKey: "repoHealth.fact.openSSF.label")]
            )
        }

        let tone: RepoHealthFactTone = aggregate >= 7 ? .good : (aggregate >= 5 ? .neutral : .bad)
        return RepoHealthDimensionScore(
            dimension: .security,
            score: clamp(aggregate * 10),
            summaryKey: "repoHealth.dimension.security",
            facts: [
                fact(
                    key: "openSSF",
                    labelKey: "repoHealth.fact.openSSF.label",
                    valueKey: "repoHealth.fact.openSSF.score.format",
                    valueArgs: [String(format: "%.1f", aggregate)],
                    tone: tone
                ),
            ]
        )
    }

    // MARK: - Fact builders

    private static func fact(
        key: String,
        labelKey: String,
        valueKey: String,
        valueArgs: [String] = [],
        tone: RepoHealthFactTone,
        linkURL: String? = nil
    ) -> RepoHealthFact {
        RepoHealthFact(
            key: key,
            labelKey: labelKey,
            valueKey: valueKey,
            valueArgs: valueArgs,
            tone: tone,
            linkURL: linkURL
        )
    }

    private static func missingFact(key: String, labelKey: String) -> RepoHealthFact {
        fact(
            key: key,
            labelKey: labelKey,
            valueKey: "repoHealth.fact.value.unknownConservative",
            tone: .missing
        )
    }

    /// Homepage 等外链：GitHub 有时只给域名,补 `https://` 以便 Link 跳转。
    private static func normalizedHTTPURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    static func grade(for score: Double) -> String {
        switch score {
        case 90...: return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        case 60..<70: return "D"
        default: return "E"
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
