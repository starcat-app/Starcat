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
                    distribution("unread", "insights.status.unread", 612, 0.477, "orange"),
                    distribution("read", "insights.status.read", 578, 0.450, "blue"),
                    distribution("using", "insights.status.using", 94, 0.073, "green")
                ],
                languageItems: [
                    distribution("swift", "Swift", 296, 0.230, "orange"),
                    distribution("typescript", "TypeScript", 244, 0.190, "blue"),
                    distribution("python", "Python", 193, 0.150, "yellow"),
                    distribution("go", "Go", 128, 0.100, "cyan"),
                    distribution("rust", "Rust", 103, 0.080, "red"),
                    distribution("other", "insights.technology.other", 320, 0.250, "secondary")
                ],
                topicItems: [
                    distribution("ai", "insights.technology.topic.ai", 286, 0.223, "purple"),
                    distribution("developerTools", "insights.technology.topic.developerTools", 211, 0.164, "blue"),
                    distribution("web", "insights.technology.topic.web", 196, 0.153, "cyan"),
                    distribution("data", "insights.technology.topic.data", 143, 0.111, "yellow"),
                    distribution("apple", "insights.technology.topic.apple", 119, 0.093, "orange"),
                    distribution("other", "insights.technology.topic.other", 329, 0.256, "secondary")
                ],
                licenseItems: [
                    distribution("mit", "MIT", 578, 0.450, "blue"),
                    distribution("apache", "Apache-2.0", 231, 0.180, "purple"),
                    distribution("gpl", "GPL", 116, 0.090, "orange"),
                    distribution("bsd", "BSD", 77, 0.060, "cyan"),
                    distribution("other", "insights.technology.license.other", 90, 0.070, "green"),
                    distribution("unknown", "insights.technology.license.unknown", 192, 0.150, "secondary")
                ],
                actionItems: [
                    action(.untagged, "insights.action.untagged", "insights.action.untagged.detail", 247, "tag.slash.fill", "orange"),
                    action(.unread, "insights.action.unread", "insights.action.unread.detail", 612, "book.closed.fill", "blue"),
                    action(.healthPending, "insights.action.healthPending", "insights.action.healthPending.detail", 173, "heart.text.square.fill", "pink"),
                    action(.openSSFPending, "insights.action.openSSFPending", "insights.action.openSSFPending.detail", 360, "shield.lefthalf.filled", "cyan"),
                    action(.maintenanceRisk, "insights.action.maintenanceRisk", "insights.action.maintenanceRisk.detail", 58, "wrench.and.screwdriver.fill", "orange"),
                    action(.securityRisk, "insights.action.securityRisk", "insights.action.securityRisk.detail", 31, "lock.trianglebadge.exclamationmark.fill", "red")
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
                    distribution("unread", "insights.status.unread", 82, 0.252, "orange"),
                    distribution("read", "insights.status.read", 176, 0.540, "blue"),
                    distribution("using", "insights.status.using", 68, 0.208, "green")
                ],
                languageItems: [
                    distribution("swift", "Swift", 104, 0.319, "orange"),
                    distribution("typescript", "TypeScript", 65, 0.199, "blue"),
                    distribution("python", "Python", 49, 0.150, "yellow"),
                    distribution("go", "Go", 33, 0.101, "cyan"),
                    distribution("rust", "Rust", 26, 0.080, "red"),
                    distribution("other", "insights.technology.other", 49, 0.151, "secondary")
                ],
                topicItems: [
                    distribution("ai", "insights.technology.topic.ai", 91, 0.279, "purple"),
                    distribution("developerTools", "insights.technology.topic.developerTools", 62, 0.190, "blue"),
                    distribution("web", "insights.technology.topic.web", 49, 0.150, "cyan"),
                    distribution("data", "insights.technology.topic.data", 42, 0.129, "yellow"),
                    distribution("apple", "insights.technology.topic.apple", 36, 0.110, "orange"),
                    distribution("other", "insights.technology.topic.other", 46, 0.142, "secondary")
                ],
                licenseItems: [
                    distribution("mit", "MIT", 153, 0.469, "blue"),
                    distribution("apache", "Apache-2.0", 59, 0.181, "purple"),
                    distribution("gpl", "GPL", 29, 0.089, "orange"),
                    distribution("bsd", "BSD", 20, 0.061, "cyan"),
                    distribution("other", "insights.technology.license.other", 23, 0.071, "green"),
                    distribution("unknown", "insights.technology.license.unknown", 42, 0.129, "secondary")
                ],
                actionItems: [
                    action(.untagged, "insights.action.untagged", "insights.action.untagged.detail", 28, "tag.slash.fill", "orange"),
                    action(.unread, "insights.action.unread", "insights.action.unread.detail", 82, "book.closed.fill", "blue"),
                    action(.missingReadme, "insights.action.missingReadme", "insights.action.missingReadme.detail", 34, "doc.questionmark.fill", "yellow"),
                    action(.missingIndexableContent, "insights.action.missingIndexableContent", "insights.action.missingIndexableContent.detail", 22, "doc.text.magnifyingglass", "yellow"),
                    action(.indexIssues, "insights.action.indexIssues", "insights.action.indexIssues.detail", 19, "exclamationmark.magnifyingglass", "red"),
                    action(.healthPending, "insights.action.healthPending", "insights.action.healthPending.detail", 41, "heart.text.square.fill", "pink"),
                    action(.openSSFPending, "insights.action.openSSFPending", "insights.action.openSSFPending.detail", 79, "shield.lefthalf.filled", "cyan"),
                    action(.maintenanceRisk, "insights.action.maintenanceRisk", "insights.action.maintenanceRisk.detail", 17, "wrench.and.screwdriver.fill", "orange"),
                    action(.securityRisk, "insights.action.securityRisk", "insights.action.securityRisk.detail", 9, "lock.trianglebadge.exclamationmark.fill", "red")
                ],
                healthCoverage: InsightsCoverage(completed: 285, total: 326),
                openSSFCoverage: InsightsCoverage(completed: 247, total: 326)
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
