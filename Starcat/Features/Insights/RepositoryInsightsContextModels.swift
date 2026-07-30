//
//  RepositoryInsightsContextModels.swift
//  Starcat
//
//  仓库洞察的结构化上下文模型与纯 XML Renderer。
//
//  关键约束：
//  - 页面、AI 和 RAG 必须消费同一份结构化快照，不能各自重新聚合远端数据。
//  - sourceHash 只描述洞察事实，不包含 generatedAt，避免同一数据重复写盘。
//  - XML 中只保留聚合指标和受控列表，不写 Issue / PR 标题或安全公告正文。
//

import CryptoKit
import Foundation

/// 带缓存时间和过期状态的远端洞察值。
struct RepositoryInsightsPreparedValue<Value: Sendable>: Sendable {
    let value: Value
    /// 本地派生值没有独立缓存时间，保持 nil，不能用“当前时间”伪造并污染 sourceHash。
    let fetchedAt: Date?
    let isStale: Bool
}

/// 页面、AI 与 RAG 共用的仓库洞察事实快照。
struct RepositoryInsightsSnapshot: Sendable {
    let repo: Repo
    let release: RepositoryReleaseInsight?
    let releaseCadence: RepositoryInsightsPreparedValue<RepositoryReleaseCadenceInsight>?
    let health: RepositoryHealthInsight?
    let openSSF: RepositoryOpenSSFInsight?
    let community: RepositoryInsightsPreparedValue<RepositoryCommunityInsight>?
    let activity: RepositoryInsightsPreparedValue<RepositoryActivityCounts>?
    let commitActivity: RepositoryInsightsPreparedValue<RepositoryCommitActivity>?
    let contributors: RepositoryInsightsPreparedValue<RepositoryContributorsInsight>?
    let security: RepositoryInsightsPreparedValue<RepositorySecurityAdvisoriesInsight>?
    let recentActivity: RepositoryInsightsPreparedValue<RepositoryRecentActivity>?
    let starHistory: StarHistorySnapshot?
    /// 本地并行读取失败数。nil 值可能只是“仓库没有该数据”，只有真正读取失败才计入 partial。
    let localFailureCount: Int

    var containsStaleData: Bool {
        [
            releaseCadence?.isStale,
            community?.isStale,
            activity?.isStale,
            commitActivity?.isStale,
            contributors?.isStale,
            security?.isStale,
            recentActivity?.isStale
        ].contains(true)
    }

    var isPartial: Bool {
        guard localFailureCount == 0 else { return true }
        guard !repo.isPrivate else {
            // 私有仓库的公共 GitHub Metrics 本来就不可用，不应把权限边界误报为加载失败。
            return starHistory == nil
        }
        return activity == nil
            || commitActivity == nil
            || contributors == nil
            || community == nil
            || security == nil
            || recentActivity == nil
            || starHistory == nil
    }
}

/// 可持久化、可直接注入 Prompt 的合法 XML 文档。
struct RepositoryInsightsDocument: Equatable, Sendable {
    static let schemaVersion = 1
    static let fileName = "insights.xml"

    let repositoryID: Int64
    let repositoryFullName: String
    let generatedAt: Date
    let sourceHash: String
    let xml: String
}

/// 把结构化洞察投影为稳定的纯 XML。
///
/// Renderer 不做文件 IO 与网络请求，因此同一快照可安全复用于 AI、RAG 和 Artifact Storage。
enum RepositoryInsightsXMLRenderer {
    private static let maximumContributorItems = 5
    private static let maximumCommitPoints = 52
    private static let maximumStarPoints = 24

    static func render(
        snapshot: RepositoryInsightsSnapshot,
        generatedAt: Date
    ) -> RepositoryInsightsDocument {
        let body = renderBody(snapshot)
        let sourceMaterial = [
            "schema_version=\(RepositoryInsightsDocument.schemaVersion)",
            "repository_id=\(snapshot.repo.id)",
            "repository=\(snapshot.repo.fullName)",
            body
        ].joined(separator: "\n")
        let sourceHash = sha256(sourceMaterial)
        let rootAttributes: [String: String?] = [
            "generated_at": dateString(generatedAt),
            "partial": String(snapshot.isPartial),
            "private": String(snapshot.repo.isPrivate),
            "repository": snapshot.repo.fullName,
            "repository_id": String(snapshot.repo.id),
            "schema_version": String(RepositoryInsightsDocument.schemaVersion),
            "source_hash": sourceHash,
            "stale": String(snapshot.containsStaleData)
        ]
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        \(openingElement("repository_insights", attributes: rootAttributes))
        \(body)
        </repository_insights>
        """
        return RepositoryInsightsDocument(
            repositoryID: snapshot.repo.id,
            repositoryFullName: snapshot.repo.fullName,
            generatedAt: generatedAt,
            sourceHash: sourceHash,
            xml: xml
        )
    }

    /// sourceHash 使用的正文保持固定顺序；Dictionary 只用于属性收集，输出时统一按 key 排序。
    private static func renderBody(_ snapshot: RepositoryInsightsSnapshot) -> String {
        var sections: [String] = [
            element(
                "metadata",
                attributes: [
                    "archived": String(snapshot.repo.isArchived),
                    "fork": String(snapshot.repo.isFork),
                    "forks": String(snapshot.repo.forksCount),
                    "open_issues": snapshot.repo.openIssuesCount.map(String.init),
                    "stars": String(snapshot.repo.starsCount),
                    "watchers": String(snapshot.repo.watchersCount)
                ]
            )
        ]

        if let release = snapshot.release {
            sections.append(
                element(
                    "latest_release",
                    attributes: [
                        "published_at": release.publishedAt.map(dateString),
                        "tag": release.tagName
                    ]
                )
            )
        }
        if let cadence = snapshot.releaseCadence {
            sections.append(
                element(
                    "release_cadence",
                    attributes: [
                        "average_interval_days": cadence.value.averageIntervalDays.map(String.init),
                        "fetched_at": cadence.fetchedAt.map(dateString),
                        "latest_published_at": dateString(cadence.value.latestPublishedAt),
                        "releases_last_year": String(cadence.value.releasesLastYear),
                        "stale": String(cadence.isStale)
                    ]
                )
            )
        }
        if let health = snapshot.health {
            sections.append(
                element(
                    "health",
                    attributes: [
                        "grade": health.grade,
                        "maintenance_score": String(health.maintenanceScore),
                        "overall_score": String(health.overallScore),
                        "partial": String(health.isPartial),
                        "popularity_score": String(health.popularityScore),
                        "quality_score": String(health.qualityScore),
                        "security_score": String(health.securityScore)
                    ]
                )
            )
        }
        if let openSSF = snapshot.openSSF {
            sections.append(
                element(
                    "openssf",
                    attributes: [
                        "score": decimal(openSSF.score, precision: 1),
                        "score_date": openSSF.scoreDate
                    ]
                )
            )
        }
        if let community = snapshot.community {
            sections.append(
                element(
                    "community",
                    attributes: [
                        "code_of_conduct": String(community.value.hasCodeOfConduct),
                        "contributing_guide": String(community.value.hasContributing),
                        "fetched_at": community.fetchedAt.map(dateString),
                        "health_percentage": String(community.value.healthPercentage),
                        "issue_template": String(community.value.hasIssueTemplate),
                        "license": String(community.value.hasLicense),
                        "pull_request_template": String(community.value.hasPullRequestTemplate),
                        "readme": String(community.value.hasReadme),
                        "stale": String(community.isStale)
                    ]
                )
            )
        }
        if let activity = snapshot.activity {
            sections.append(
                element(
                    "activity",
                    attributes: [
                        "closed_issues": String(activity.value.closedIssues),
                        "created_issues": String(activity.value.createdIssues),
                        "created_pull_requests": String(activity.value.createdPullRequests),
                        "fetched_at": activity.fetchedAt.map(dateString),
                        "issue_throughput": activity.value.issueThroughput.map {
                            decimal($0, precision: 4)
                        },
                        "merged_pull_requests": String(activity.value.mergedPullRequests),
                        "net_issue_change": String(activity.value.netIssueChange),
                        "pull_request_throughput": activity.value.pullRequestThroughput.map {
                            decimal($0, precision: 4)
                        },
                        "range_days": "30",
                        "stale": String(activity.isStale)
                    ]
                )
            )
        }
        if let commitActivity = snapshot.commitActivity {
            sections.append(renderCommitActivity(commitActivity))
        }
        if let contributors = snapshot.contributors {
            sections.append(renderContributors(contributors))
        }
        if let security = snapshot.security {
            sections.append(
                element(
                    "security_advisories",
                    attributes: [
                        "fetched_at": security.fetchedAt.map(dateString),
                        "high_or_critical_count": String(security.value.highOrCriticalCount),
                        "latest_published_at": security.value.latestPublishedAt.map(dateString),
                        "published_count": String(security.value.advisories.count),
                        "stale": String(security.isStale)
                    ]
                )
            )
        }
        if let recentActivity = snapshot.recentActivity {
            let events = recentActivity.value.events
            sections.append(
                element(
                    "recent_activity",
                    attributes: [
                        "fetched_at": recentActivity.fetchedAt.map(dateString),
                        "issue_events": String(events.count { $0.kind == .issue }),
                        "latest_event_at": events.map(\.occurredAt).max().map(dateString),
                        "pull_request_events": String(events.count { $0.kind == .pullRequest }),
                        "range_days": "30",
                        "stale": String(recentActivity.isStale)
                    ]
                )
            )
        }
        if let starHistory = snapshot.starHistory {
            sections.append(renderStarHistory(starHistory))
        }

        return sections.map { indent($0, spaces: 2) }.joined(separator: "\n")
    }

    private static func renderCommitActivity(
        _ prepared: RepositoryInsightsPreparedValue<RepositoryCommitActivity>
    ) -> String {
        let value = prepared.value
        let pulse = value.maintenancePulse
        let points = Array(
            value.points
                .sorted { $0.weekStart < $1.weekStart }
                .suffix(maximumCommitPoints)
        )
        let children = points.map { point in
            element(
                "week",
                attributes: [
                    "commits": String(point.commits),
                    "start": dateString(point.weekStart)
                ]
            )
        }.joined(separator: "\n")
        return container(
            "commit_activity",
            attributes: [
                "fetched_at": prepared.fetchedAt.map(dateString),
                "previous_period_change_percent": pulse?.comparisonPercentage.map(String.init),
                "recent_4_weeks_active_weeks": pulse.map { String($0.activeWeeks) },
                "recent_4_weeks_commits": pulse.map { String($0.recentCommits) },
                "sample_weeks": String(value.points.count),
                "stale": String(prepared.isStale)
            ],
            children: children
        )
    }

    private static func renderContributors(
        _ prepared: RepositoryInsightsPreparedValue<RepositoryContributorsInsight>
    ) -> String {
        let value = prepared.value
        let concentration = value.concentration
        let ordered = value.contributors
            .sorted {
                if $0.commits != $1.commits { return $0.commits > $1.commits }
                // GitHub login 是 ASCII 标识；直接按 Unicode 标量序比本地化排序更适合稳定 hash。
                return $0.login < $1.login
            }
            .prefix(maximumContributorItems)
        let children = ordered.map { contributor in
            element(
                "contributor",
                attributes: [
                    "commits": String(max(0, contributor.commits)),
                    "login": contributor.login
                ]
            )
        }.joined(separator: "\n")
        return container(
            "contributors",
            attributes: [
                "fetched_at": prepared.fetchedAt.map(dateString),
                "sampled_count": String(value.contributors.count),
                "stale": String(prepared.isStale),
                "top_contributor_share": concentration.map {
                    decimal($0.topContributorShare, precision: 4)
                },
                "top_three_share": concentration.map {
                    decimal($0.topThreeShare, precision: 4)
                }
            ],
            children: children
        )
    }

    private static func renderStarHistory(_ snapshot: StarHistorySnapshot) -> String {
        let ordered = snapshot.points.sorted { $0.date < $1.date }
        let sampled = downsample(ordered, maximumCount: maximumStarPoints)
        let children = sampled.map { point in
            element(
                "point",
                attributes: [
                    "count": String(point.count),
                    "date": StarHistoryDateCodec.dayString(from: point.date),
                    "precision": point.precision.rawValue,
                    "source": point.source.rawValue
                ]
            )
        }.joined(separator: "\n")
        let sources = Set(ordered.map(\.source.rawValue)).sorted().joined(separator: ",")
        let precisions = Set(ordered.map(\.precision.rawValue)).sorted().joined(separator: ",")
        return container(
            "star_history",
            attributes: [
                "coverage_start": snapshot.coverageStart.map(dateString),
                "current_stars": ordered.last.map { String($0.count) },
                "growth_30_days": growth(in: ordered, days: 30, toleranceDays: 10).map(String.init),
                "growth_365_days": growth(in: ordered, days: 365, toleranceDays: 14).map(String.init),
                "point_count": String(ordered.count),
                "precisions": precisions,
                "range": snapshot.range.rawValue,
                "sampled_point_count": String(sampled.count),
                "sources": sources,
                "updated_at": snapshot.updatedAt.map(dateString)
            ],
            children: children
        )
    }

    /// 均匀抽取首尾和中间点；只依赖排序后下标，保证同一输入得到完全一致的 XML。
    static func downsample(
        _ points: [StarHistoryPoint],
        maximumCount: Int
    ) -> [StarHistoryPoint] {
        guard maximumCount > 1, points.count > maximumCount else {
            return maximumCount > 0 ? Array(points.prefix(maximumCount)) : []
        }
        let lastIndex = points.count - 1
        var indices: [Int] = []
        indices.reserveCapacity(maximumCount)
        for position in 0..<maximumCount {
            let ratio = Double(position) / Double(maximumCount - 1)
            let index = Int((ratio * Double(lastIndex)).rounded())
            if indices.last != index {
                indices.append(index)
            }
        }
        return indices.map { points[$0] }
    }

    private static func growth(
        in points: [StarHistoryPoint],
        days: Int,
        toleranceDays: Int
    ) -> Int? {
        guard let latest = points.last else { return nil }
        let target = latest.date.addingTimeInterval(-TimeInterval(days) * 86_400)
        let tolerance = TimeInterval(toleranceDays) * 86_400
        guard let baseline = points.min(by: {
            abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target))
        }), abs(baseline.date.timeIntervalSince(target)) <= tolerance
        else {
            return nil
        }
        return latest.count - baseline.count
    }

    private static func container(
        _ name: String,
        attributes: [String: String?],
        children: String
    ) -> String {
        guard !children.isEmpty else { return element(name, attributes: attributes) }
        return """
        \(openingElement(name, attributes: attributes))
        \(indent(children, spaces: 2))
        </\(name)>
        """
    }

    private static func element(
        _ name: String,
        attributes: [String: String?]
    ) -> String {
        let rendered = renderedAttributes(attributes)
        return rendered.isEmpty ? "<\(name) />" : "<\(name) \(rendered) />"
    }

    private static func openingElement(
        _ name: String,
        attributes: [String: String?]
    ) -> String {
        let rendered = renderedAttributes(attributes)
        return rendered.isEmpty ? "<\(name)>" : "<\(name) \(rendered)>"
    }

    private static func renderedAttributes(_ attributes: [String: String?]) -> String {
        attributes
            .compactMap { key, value in
                value.map { "\(key)=\"\(escape($0))\"" }
            }
            .sorted()
            .joined(separator: " ")
    }

    private static func indent(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    private static func decimal(_ value: Double, precision: Int) -> String {
        String(
            format: "%.\(precision)f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter.shared.string(from: date)
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
