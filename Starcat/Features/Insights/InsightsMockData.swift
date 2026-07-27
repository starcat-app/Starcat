//
//  InsightsMockData.swift
//  Starcat
//
//  洞察中心前端阶段的确定性演示数据。这里故意不读取数据库或网络，确保 UI 能独立
//  验收；真实 Provider 接入后应替换调用方，不要让 Mock 混入生产统计口径。
//

import Foundation

enum InsightsMockData {

    /// 固定生成时间让截图、Preview 与单元测试稳定，不随运行时钟产生无意义差异。
    static let generatedAt = Date(timeIntervalSince1970: 1_785_052_800)

    static func myInsights(scope: InsightsScope) -> MyInsightsSnapshot {
        switch scope {
        case .starred:
            return MyInsightsSnapshot(
                scope: scope,
                generatedAt: generatedAt,
                metrics: [
                    metric("projects", "insights.metric.projects", 1_284, "insights.metric.projects.detail", "star.fill", "yellow"),
                    metric("new", "insights.metric.recent", 86, "insights.metric.recent.detail", "clock.arrow.circlepath", "blue"),
                    metric("using", "insights.metric.using", 94, "insights.metric.using.detail", "hammer.fill", "green"),
                    metric("organized", "insights.metric.organized", 867, "insights.metric.organized.detail", "checkmark.seal.fill", "purple")
                ],
                statusItems: [
                    distribution("unread", "未读", 612, 0.477, "orange"),
                    distribution("read", "已读", 578, 0.450, "blue"),
                    distribution("using", "正在使用", 94, 0.073, "green")
                ],
                languageItems: [
                    distribution("swift", "Swift", 296, 0.230, "orange"),
                    distribution("typescript", "TypeScript", 244, 0.190, "blue"),
                    distribution("python", "Python", 193, 0.150, "yellow"),
                    distribution("go", "Go", 128, 0.100, "cyan"),
                    distribution("rust", "Rust", 103, 0.080, "red"),
                    distribution("other", "其他", 320, 0.250, "secondary")
                ],
                actionItems: [
                    action(.untagged, "insights.action.untagged", "insights.action.untagged.detail", 247, "tag.slash.fill", "orange"),
                    action(.unread, "insights.action.unread", "insights.action.unread.detail", 612, "book.closed.fill", "blue"),
                    action(.healthPending, "insights.action.healthPending", "insights.action.healthPending.detail", 173, "heart.text.square.fill", "pink")
                ],
                healthCoverage: InsightsCoverage(completed: 1_111, total: 1_284),
                openSSFCoverage: InsightsCoverage(completed: 924, total: 1_284)
            )

        case .knowledge:
            return MyInsightsSnapshot(
                scope: scope,
                generatedAt: generatedAt,
                metrics: [
                    metric("projects", "insights.metric.projects", 326, "insights.metric.knowledgeProjects.detail", "heart.fill", "pink"),
                    metric("new", "insights.metric.recent", 31, "insights.metric.knowledgeRecent.detail", "clock.arrow.circlepath", "blue"),
                    metric("using", "insights.metric.using", 68, "insights.metric.using.detail", "hammer.fill", "green"),
                    metric("organized", "insights.metric.organized", 298, "insights.metric.organized.detail", "checkmark.seal.fill", "purple")
                ],
                statusItems: [
                    distribution("unread", "未读", 82, 0.252, "orange"),
                    distribution("read", "已读", 176, 0.540, "blue"),
                    distribution("using", "正在使用", 68, 0.208, "green")
                ],
                languageItems: [
                    distribution("swift", "Swift", 104, 0.319, "orange"),
                    distribution("typescript", "TypeScript", 65, 0.199, "blue"),
                    distribution("python", "Python", 49, 0.150, "yellow"),
                    distribution("go", "Go", 33, 0.101, "cyan"),
                    distribution("rust", "Rust", 26, 0.080, "red"),
                    distribution("other", "其他", 49, 0.151, "secondary")
                ],
                actionItems: [
                    action(.untagged, "insights.action.untagged", "insights.action.untagged.detail", 28, "tag.slash.fill", "orange"),
                    action(.unread, "insights.action.unread", "insights.action.unread.detail", 82, "book.closed.fill", "blue"),
                    action(.indexIssues, "insights.action.indexIssues", "insights.action.indexIssues.detail", 19, "exclamationmark.magnifyingglass", "red"),
                    action(.healthPending, "insights.action.healthPending", "insights.action.healthPending.detail", 41, "heart.text.square.fill", "pink")
                ],
                healthCoverage: InsightsCoverage(completed: 285, total: 326),
                openSSFCoverage: InsightsCoverage(completed: 247, total: 326)
            )
        }
    }

    static func repositoryInsights(for repo: Repo) -> RepositoryInsightsSnapshot {
        let currentStars = max(repo.starsCount, 8_420)
        let baseline = max(currentStars - 3_840, 300)
        let monthlyGrowth = max(Int(Double(currentStars) * 0.038), 126)
        let yearlyGrowth = max(Int(Double(currentStars) * 0.286), 1_420)
        let seed = Int(abs(repo.id) % 17)

        return RepositoryInsightsSnapshot(
            repoID: repo.id,
            fullName: repo.fullName,
            generatedAt: generatedAt,
            currentStars: currentStars,
            starGrowth30Days: monthlyGrowth,
            starGrowthOneYear: yearlyGrowth,
            starHistory: makeStarHistory(baseline: baseline, current: currentStars, seed: seed),
            activityMetrics: [
                activity("pullRequests", "insights.repo.activity.pullRequests", 48 + seed, 12, "arrow.triangle.pull", "purple"),
                activity("issues", "insights.repo.activity.issues", 37 + seed, -4, "record.circle", "red"),
                activity("commits", "insights.repo.activity.commits", 286 + seed * 3, 23, "point.topleft.down.to.point.bottomright.curvepath", "green"),
                activity("releases", "insights.repo.activity.releases", 6, 2, "tag.fill", "blue")
            ],
            commitPoints: [24, 31, 19, 42, 37, 55, 48, 63, 52, 71, 67, 84].enumerated().map {
                RepositoryCommitPoint(id: $0.offset, weekLabel: "W\($0.offset + 1)", commits: $0.element + seed)
            },
            contributors: [
                contributor("sindresorhus", 184, "purple"),
                contributor("mattt", 129, "blue"),
                contributor("cassidoo", 96, "pink"),
                contributor("antfu", 78, "green"),
                contributor("yyx990803", 61, "orange")
            ],
            healthDimensions: [
                health("maintenance", "insights.repo.health.maintenance", 91, "wrench.and.screwdriver.fill", "green"),
                health("popularity", "insights.repo.health.popularity", 88, "chart.line.uptrend.xyaxis", "blue"),
                health("quality", "insights.repo.health.quality", 82, "checkmark.seal.fill", "purple"),
                health("security", "insights.repo.health.security", 76, "lock.shield.fill", "orange")
            ],
            communitySignals: [
                signal("readme", "insights.repo.signal.readme", "insights.repo.signal.available", .positive, "doc.text.fill"),
                signal("license", "insights.repo.signal.license", "insights.repo.signal.mit", .positive, "checkmark.seal.fill"),
                signal("conduct", "insights.repo.signal.conduct", "insights.repo.signal.available", .positive, "person.2.fill"),
                signal("contributing", "insights.repo.signal.contributing", "insights.repo.signal.missing", .warning, "hand.raised.fill")
            ],
            securitySignals: [
                signal("openssf", "insights.repo.signal.openssf", "insights.repo.signal.openssfScore", .positive, "shield.checkered"),
                signal("advisories", "insights.repo.signal.advisories", "insights.repo.signal.none", .positive, "lock.fill"),
                signal("dependabot", "insights.repo.signal.dependabot", "insights.repo.signal.enabled", .positive, "arrow.triangle.2.circlepath"),
                signal("branch", "insights.repo.signal.branchProtection", "insights.repo.signal.partial", .warning, "point.3.filled.connected.trianglepath.dotted")
            ],
            timelineItems: [
                timeline("release", "发布 v2.8.0", "包含 18 项改进与 6 项修复", "insights.time.twoDays", "tag.fill", "blue"),
                timeline("pr", "合并 12 个 Pull Request", "来自 8 位贡献者", "insights.time.thisWeek", "arrow.triangle.pull", "purple"),
                timeline("issue", "关闭 9 个 Issue", "平均响应时间 14 小时", "insights.time.thisWeek", "checkmark.circle.fill", "green"),
                timeline("commit", "主分支持续更新", "过去 30 天共有 286 次提交", "insights.time.today", "point.topleft.down.to.point.bottomright.curvepath", "orange")
            ]
        )
    }

    private static func makeStarHistory(baseline: Int, current: Int, seed: Int) -> [StarHistoryPoint] {
        let weights = [0.00, 0.05, 0.11, 0.18, 0.26, 0.35, 0.43, 0.54, 0.64, 0.73, 0.82, 0.91, 1.00]
        let start = generatedAt.addingTimeInterval(-360 * 86_400)
        return weights.enumerated().map { index, weight in
            let organicVariation = index == weights.count - 1 ? 0 : ((index + seed) % 3) * 19
            let count = min(current, baseline + Int(Double(current - baseline) * weight) + organicVariation)
            return StarHistoryPoint(
                date: start.addingTimeInterval(Double(index) * 30 * 86_400),
                count: count
            )
        }
    }

    private static func metric(
        _ id: String,
        _ titleKey: String,
        _ value: Int,
        _ detailKey: String,
        _ systemImage: String,
        _ tintName: String
    ) -> InsightsMetric {
        InsightsMetric(
            id: id,
            titleKey: titleKey,
            value: value,
            detailKey: detailKey,
            systemImage: systemImage,
            tintName: tintName
        )
    }

    private static func distribution(
        _ id: String,
        _ title: String,
        _ count: Int,
        _ fraction: Double,
        _ colorName: String
    ) -> InsightsDistributionItem {
        InsightsDistributionItem(id: id, title: title, count: count, fraction: fraction, colorName: colorName)
    }

    private static func action(
        _ id: InsightsSelection,
        _ titleKey: String,
        _ detailKey: String,
        _ count: Int,
        _ systemImage: String,
        _ tintName: String
    ) -> InsightsActionItem {
        InsightsActionItem(
            id: id,
            titleKey: titleKey,
            detailKey: detailKey,
            count: count,
            systemImage: systemImage,
            tintName: tintName
        )
    }

    private static func activity(
        _ id: String,
        _ titleKey: String,
        _ value: Int,
        _ delta: Int,
        _ systemImage: String,
        _ tintName: String
    ) -> RepositoryActivityMetric {
        RepositoryActivityMetric(
            id: id,
            titleKey: titleKey,
            value: value,
            delta: delta,
            systemImage: systemImage,
            tintName: tintName
        )
    }

    private static func contributor(_ login: String, _ commits: Int, _ colorName: String) -> RepositoryContributor {
        RepositoryContributor(id: login, login: login, commits: commits, colorName: colorName)
    }

    private static func health(
        _ id: String,
        _ titleKey: String,
        _ score: Int,
        _ systemImage: String,
        _ tintName: String
    ) -> RepositoryHealthDimensionItem {
        RepositoryHealthDimensionItem(
            id: id,
            titleKey: titleKey,
            score: score,
            systemImage: systemImage,
            tintName: tintName
        )
    }

    private static func signal(
        _ id: String,
        _ titleKey: String,
        _ detailKey: String,
        _ state: RepositorySignal.State,
        _ systemImage: String
    ) -> RepositorySignal {
        RepositorySignal(
            id: id,
            titleKey: titleKey,
            detailKey: detailKey,
            state: state,
            systemImage: systemImage
        )
    }

    private static func timeline(
        _ id: String,
        _ title: String,
        _ detail: String,
        _ relativeTimeKey: String,
        _ systemImage: String,
        _ tintName: String
    ) -> RepositoryTimelineItem {
        RepositoryTimelineItem(
            id: id,
            title: title,
            detail: detail,
            relativeTimeKey: relativeTimeKey,
            systemImage: systemImage,
            tintName: tintName
        )
    }
}
