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
        let status: RepoHealthFetchStatus = security.missing.isEmpty ? .success : .partial
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

    private static func maintenanceScore(repo: Repo, latestRelease: ReleaseRecord?, now: Date) -> RepoHealthDimensionScore {
        var score = 50.0
        var evidence: [String] = []
        var missing: [String] = []

        if repo.isArchived {
            score -= 45
            evidence.append("Repository is archived.")
        }

        if let pushedAt = repo.pushedAt.flatMap(ISO8601DateFormatter.shared.date(from:)) {
            let days = now.timeIntervalSince(pushedAt) / 86_400
            switch days {
            case ..<30:
                score += 30
                evidence.append("Pushed within 30 days.")
            case ..<180:
                score += 15
                evidence.append("Pushed within 180 days.")
            case ..<365:
                score -= 5
                evidence.append("No push in the last 180 days.")
            default:
                score -= 20
                evidence.append("No push in the last year.")
            }
        } else {
            missing.append("pushed_at")
        }

        if let releaseDate = latestRelease?.publishedAt.flatMap(ISO8601DateFormatter.shared.date(from:)) {
            let days = now.timeIntervalSince(releaseDate) / 86_400
            if days < 180 {
                score += 15
                evidence.append("Recent release found.")
            } else if days > 365 {
                score -= 10
                evidence.append("Latest release is older than one year.")
            }
        } else {
            missing.append("latest_release")
        }

        return RepoHealthDimensionScore(
            dimension: .maintenance,
            score: clamp(score),
            summaryKey: "repoHealth.dimension.maintenance",
            evidence: evidence,
            missing: missing
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
            evidence: [
                "Stars: \(repo.starsCount)",
                "Forks: \(repo.forksCount)",
                "Watchers: \(repo.watchersCount)"
            ],
            missing: []
        )
    }

    private static func qualityScore(repo: Repo) -> RepoHealthDimensionScore {
        var score = 35.0
        var evidence: [String] = []
        var missing: [String] = []

        if repo.license?.isEmpty == false {
            score += 15
            evidence.append("License is declared.")
        } else {
            missing.append("license")
        }

        if !repo.topicsArray.isEmpty {
            score += 15
            evidence.append("Topics are declared.")
        } else {
            missing.append("topics")
        }

        if repo.homepage?.isEmpty == false {
            score += 10
            evidence.append("Homepage is declared.")
        }

        if repo.defaultBranch?.isEmpty == false {
            score += 10
            evidence.append("Default branch is known.")
        } else {
            missing.append("default_branch")
        }

        if let openIssues = repo.openIssuesCount {
            if openIssues <= 20 {
                score += 10
                evidence.append("Open issues count is low.")
            } else if openIssues > 500 {
                score -= 10
                evidence.append("Open issues count is high.")
            }
        } else {
            missing.append("open_issues_count")
        }

        return RepoHealthDimensionScore(
            dimension: .quality,
            score: clamp(score),
            summaryKey: "repoHealth.dimension.quality",
            evidence: evidence,
            missing: missing
        )
    }

    private static func securityScore(openSSF: OpenSSFScoreRecord?) -> RepoHealthDimensionScore {
        guard let openSSF, openSSF.fetchStatus == .success, let aggregate = openSSF.aggregateScore else {
            return RepoHealthDimensionScore(
                dimension: .security,
                score: 50,
                summaryKey: "repoHealth.dimension.security",
                evidence: [],
                missing: ["openssf_score"]
            )
        }

        return RepoHealthDimensionScore(
            dimension: .security,
            score: clamp(aggregate * 10),
            summaryKey: "repoHealth.dimension.security",
            evidence: ["OpenSSF Scorecard: \(String(format: "%.1f", aggregate))"],
            missing: []
        )
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

