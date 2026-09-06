//
//  ReadmeStarHistoryPreview.swift
//  Starcat
//
//  README 末尾 Star History 摘要的数据编排与安全 HTML/SVG 渲染。
//
//  关键约束：
//  - README 首屏不加载历史；只有 WebView 上报接近底部后才读取缓存并刷新。
//  - 先呈现 SQLite 中可用的 GH Archive 缓存，再复用 Repository 的 ETag / 进程内
//    去重刷新；远端失败不会清空已经显示的缓存曲线。
//  - 只输出固定模板和纯文本转义后的内容，远端字段不能成为标签、属性或脚本。
//  - 全历史在 Snapshot 更新时只建模一次，最多保留 90 个绘制点；滚动期间不做 O(n) 计算。
//

import Foundation

/// SwiftUI 交给 `ReadmeWebView` 的不可变 DOM 更新状态。
///
/// `revision` 是轻量身份，WebView 用它跳过重复 JavaScript；`html == nil` 表示移除摘要。
struct ReadmeStarHistoryRenderState: Equatable, Sendable {
    let revision: String
    let html: String?

    static let empty = ReadmeStarHistoryRenderState(revision: "empty", html: nil)
}

/// README 摘要比洞察页更克制：只展示公开仓库中足以形成历史曲线的 GH Archive 数据。
enum ReadmeStarHistoryVisibilityPolicy {
    static func shouldDisplay(
        repo: Repo,
        projectVisibility: ProjectVisibility?,
        snapshot: StarHistorySnapshot
    ) -> Bool {
        guard !repo.isPrivate,
              projectVisibility != .private,
              projectVisibility != .internal,
              snapshot.range == .all,
              snapshot.points.count >= 2
        else {
            return false
        }
        return snapshot.points.contains { $0.source == .ghArchive }
    }
}

/// README Star History 的按需状态机。
///
/// SwiftUI 仍持有展示状态；Repository actor 继续作为 SQLite、ETag、请求合并和远端
/// 数据写入的唯一来源。这里不增加第二份业务缓存，只负责 cache-first 上屏与 generation 守门。
@MainActor
@Observable
final class ReadmeStarHistoryViewModel {
    typealias ProjectVisibilityProvider = @Sendable (Int64) async -> ProjectVisibility?

    private struct LoadIdentity: Hashable {
        let repoID: Int64
        let databaseScopeRevision: UInt64
        let localeIdentifier: String

        var revisionPrefix: String {
            "\(repoID)|\(databaseScopeRevision)|\(localeIdentifier)"
        }
    }

    private let repository: any RepoStarHistoryRepositoryProtocol
    private let projectVisibilityProvider: ProjectVisibilityProvider
    private var generation: UInt64 = 0
    private var activeIdentity: LoadIdentity?
    private var loadingIdentity: LoadIdentity?

    private(set) var renderState: ReadmeStarHistoryRenderState = .empty

    init(
        repository: any RepoStarHistoryRepositoryProtocol,
        projectVisibilityProvider: @escaping ProjectVisibilityProvider
    ) {
        self.repository = repository
        self.projectVisibilityProvider = projectVisibilityProvider
    }

    /// WebView 每份文档只触发一次；这里仍按身份去重，防止 SwiftUI 更新重复提交任务。
    func loadIfNeeded(
        repo: Repo,
        databaseScopeRevision: UInt64,
        locale: Locale
    ) async {
        // 调用方会在切仓/切账号时取消 Task；先检查可挡住“已取消但尚未开始”的任务。
        guard !Task.isCancelled else { return }
        let identity = LoadIdentity(
            repoID: repo.id,
            databaseScopeRevision: databaseScopeRevision,
            localeIdentifier: locale.identifier
        )
        if activeIdentity != identity {
            generation &+= 1
            activeIdentity = identity
            loadingIdentity = nil
            renderState = ReadmeStarHistoryRenderState(
                revision: "\(identity.revisionPrefix)|empty",
                html: nil
            )
        }
        guard loadingIdentity != identity else { return }

        generation &+= 1
        let requestedGeneration = generation
        loadingIdentity = identity
        defer {
            if owns(requestedGeneration, identity: identity) {
                loadingIdentity = nil
            }
        }

        // `Repo.isPrivate` 已足以拒绝公共历史，先短路可省掉一次项目表读取。
        guard owns(requestedGeneration, identity: identity), !repo.isPrivate else { return }
        let visibility = await projectVisibilityProvider(repo.id)
        guard owns(requestedGeneration, identity: identity),
              visibility != .private,
              visibility != .internal
        else { return }

        // 先读持久缓存。即使后续网络较慢或失败，用户到达 README 末尾时也能立即看到旧曲线。
        if let cached = try? await repository.cached(repo: repo, range: .all),
           owns(requestedGeneration, identity: identity) {
            applyIfVisible(cached, repo: repo, visibility: visibility, identity: identity, locale: locale)
        }

        // Repository 内部继续处理 ETag、304、同仓请求合并与本进程已加载短路。
        // README 摘要不轮询 202，避免用户只是阅读文档时产生持续后台请求。
        guard owns(requestedGeneration, identity: identity) else { return }
        guard let refreshed = try? await repository.refresh(
            repo: repo,
            range: .all,
            forceRefresh: false
        ), owns(requestedGeneration, identity: identity) else { return }

        applyIfVisible(refreshed, repo: repo, visibility: visibility, identity: identity, locale: locale)
    }

    /// 切仓、切账号或退出 README 模式时只让旧结果失去写回资格。
    ///
    /// 底层 Repository 的共享刷新可能仍会完成并落入 SQLite，供下次进入直接命中缓存。
    func cancel() {
        generation &+= 1
        activeIdentity = nil
        loadingIdentity = nil
        renderState = .empty
    }

    private func applyIfVisible(
        _ snapshot: StarHistorySnapshot,
        repo: Repo,
        visibility: ProjectVisibility?,
        identity: LoadIdentity,
        locale: Locale
    ) {
        guard ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: visibility,
            snapshot: snapshot
        ) else { return }

        let model = StarHistoryChartRenderModel(
            points: snapshot.points,
            range: .all,
            repositoryCreatedAt: repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
        )
        guard let html = ReadmeStarHistoryHTMLRenderer.render(
            snapshot: snapshot,
            model: model,
            repositoryName: repo.fullName,
            repositoryOwner: repo.owner,
            locale: locale
        ) else { return }

        let updatedToken = snapshot.updatedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "unknown"
        let lastCount = snapshot.points.last?.count ?? 0
        renderState = ReadmeStarHistoryRenderState(
            revision: "\(identity.revisionPrefix)|\(updatedToken)|\(snapshot.points.count)|\(lastCount)",
            html: html
        )
    }

    private func owns(_ requestedGeneration: UInt64, identity: LoadIdentity) -> Bool {
        !Task.isCancelled && generation == requestedGeneration && activeIdentity == identity
    }
}

/// 生成 README 内部的固定 HTML 与轻量 SVG。所有动态文本先转义，坐标只来自本地 Double。
enum ReadmeStarHistoryHTMLRenderer {
    private enum Canvas {
        static let width = 820.0
        static let height = 330.0
        static let left = 62.0
        static let right = 18.0
        static let top = 18.0
        static let bottom = 44.0
    }

    static func render(
        snapshot: StarHistorySnapshot,
        model: StarHistoryChartRenderModel,
        repositoryName: String,
        repositoryOwner: String,
        locale: Locale
    ) -> String? {
        guard snapshot.range == .all,
              snapshot.points.count >= 2,
              model.renderedPoints.count >= 2
        else { return nil }

        let title = escape(String.l10n("readme.starHistory.title"))
        let chartTitle = escape(String.l10n("readme.starHistory.chartTitle"))
        let attributionPrefix = escape(String.l10n("readme.starHistory.poweredByPrefix"))
        let allRange = escape(String.l10n("insights.repo.star.range.all"))
        let source = escape(String.l10n("insights.repo.star.source.estimated"))
        let currentLabel = escape(String.l10n("insights.repo.star.current"))
        let updatedLabel = escape(String.l10n("insights.repo.star.updated"))
        let repositoryName = escape(repositoryName)
        let repositoryAvatarURL = escape(RepoAvatarURL.from(owner: repositoryOwner))
        let repositoryInitial = escape(repositoryOwner.first.map { String($0).uppercased() } ?? "•")
        let latestPoint = model.renderedPoints.max { $0.date < $1.date }
        let latestCount = latestPoint?.count ?? 0
        let latestCountText = escape(latestCount.formatted(.number.locale(locale)))
        let dataThroughText = escape(String(
            format: String.l10n("readme.starHistory.dataThroughFormat"),
            latestPoint.map { dateText($0.date, locale: locale) }
                ?? String.l10n("insights.repo.state.noData")
        ))
        let updatedText = snapshot.updatedAt.map { escape(dateText($0, locale: locale)) }
            ?? escape(String.l10n("insights.repo.state.noData"))
        let accessibilitySummary = escape(
            "\(chartTitle), \(repositoryName), \(allRange), \(currentLabel) \(latestCountText), \(source)"
        )

        let plotWidth = Canvas.width - Canvas.left - Canvas.right
        let plotHeight = Canvas.height - Canvas.top - Canvas.bottom
        let xDuration = max(1, model.xDomain.upperBound.timeIntervalSince(model.xDomain.lowerBound))
        // 全历史图从 0 到当前序列峰值等分，纵轴数字与曲线高度可以直接对应。
        let yMaximum = max(1, Double(model.renderedPoints.map(\.count).max() ?? 0))

        func x(_ date: Date) -> Double {
            Canvas.left + date.timeIntervalSince(model.xDomain.lowerBound) / xDuration * plotWidth
        }
        func y(_ value: Int) -> Double {
            Canvas.top + (yMaximum - Double(value)) / yMaximum * plotHeight
        }

        let polyline: String = model.renderedPoints
            .map { "\(decimal(x($0.date))),\(decimal(y($0.count)))" }
            .joined(separator: " ")
        let baselineY = decimal(Canvas.top + plotHeight)
        let firstX = decimal(x(model.renderedPoints[0].date))
        let lastX = decimal(x(model.renderedPoints[model.renderedPoints.count - 1].date))
        let areaPoints: String = "\(firstX),\(baselineY) \(polyline) \(lastX),\(baselineY)"
        let endpointX = decimal(x(latestPoint?.date ?? model.xDomain.upperBound))
        let endpointY = decimal(y(latestCount))
        // GRDB 的 `SQL` 也实现了字符串插值；这里必须明确返回 `String`，否则
        // `map + joined` 可能把 SVG 片段推断成 SQL，并把 SQL 调试描述写进 HTML。
        let xTicks: String = model.xAxisDates.enumerated().map { index, date -> String in
            let tickX = decimal(x(date))
            let label = escape(axisDateText(date, domain: model.xDomain, locale: locale))
            let anchor = index == 0 ? "start" : (index == model.xAxisDates.count - 1 ? "end" : "middle")
            return """
            <line class="starcat-star-history-grid starcat-star-history-grid-vertical" x1="\(tickX)" y1="\(decimal(Canvas.top))" x2="\(tickX)" y2="\(baselineY)"></line>
            <text class="starcat-star-history-axis starcat-star-history-axis-x" x="\(tickX)" y="\(decimal(Canvas.height - 8))" text-anchor="\(anchor)">\(label)</text>
            """
        }.joined(separator: "\n")
        let yTicks: String = stride(from: 0, through: 5, by: 1).map { index -> String in
            let progress = Double(index) / 5
            let value = yMaximum * progress
            let tickY = Canvas.top + (1 - progress) * plotHeight
            let label = escape(axisValueText(value, locale: locale))
            return """
            <line class="starcat-star-history-grid starcat-star-history-grid-horizontal" x1="\(decimal(Canvas.left))" y1="\(decimal(tickY))" x2="\(decimal(Canvas.left + plotWidth))" y2="\(decimal(tickY))"></line>
            <text class="starcat-star-history-axis starcat-star-history-axis-y" x="\(decimal(Canvas.left - 10))" y="\(decimal(tickY + 4))" text-anchor="end">\(label)</text>
            """
        }.joined(separator: "\n")

        return """
        <section class="starcat-star-history" aria-labelledby="starcat-star-history-title">
          <header class="starcat-star-history-header">
            <div class="starcat-star-history-heading">
              <span class="starcat-star-history-heading-icon" aria-hidden="true">★</span>
              <h2 id="starcat-star-history-title">\(title)</h2>
              <span class="starcat-star-history-range">\(allRange)</span>
            </div>
            <span class="starcat-star-history-attribution">
              <span>\(attributionPrefix)</span>
              <strong>Starcat</strong>
            </span>
          </header>
          <div class="starcat-star-history-card">
            <header class="starcat-star-history-card-header">
              <div class="starcat-star-history-repository">
                <span class="starcat-star-history-avatar" aria-hidden="true">
                  <span class="starcat-star-history-avatar-fallback">\(repositoryInitial)</span>
                  <img src="\(repositoryAvatarURL)" alt="" width="32" height="32" loading="lazy" decoding="async">
                </span>
                <div class="starcat-star-history-card-copy">
                  <span class="starcat-star-history-card-kicker">\(chartTitle)</span>
                  <h3>\(repositoryName)</h3>
                </div>
              </div>
              <div class="starcat-star-history-current" aria-label="\(currentLabel) \(latestCountText)">
                <span class="starcat-star-history-current-star" aria-hidden="true">★</span>
                <strong class="starcat-star-history-current-count">\(latestCountText)</strong>
              </div>
            </header>
            <div class="starcat-star-history-chart">
              <svg viewBox="0 0 \(Int(Canvas.width)) \(Int(Canvas.height))" role="img" aria-label="\(accessibilitySummary)" preserveAspectRatio="xMidYMid meet">
                <title>\(accessibilitySummary)</title>
                <polygon class="starcat-star-history-area" points="\(areaPoints)"></polygon>
                \(xTicks)
                \(yTicks)
                <polyline class="starcat-star-history-line" points="\(polyline)"></polyline>
                <circle class="starcat-star-history-endpoint" cx="\(endpointX)" cy="\(endpointY)" r="5"></circle>
              </svg>
            </div>
            <footer class="starcat-star-history-footer">
              <span>\(dataThroughText)</span>
              <span aria-hidden="true">·</span>
              <span>\(updatedLabel) \(updatedText)</span>
            </footer>
          </div>
        </section>
        """
    }

    private static func dateText(_ date: Date, locale: Locale) -> String {
        date.formatted(
            .dateTime
                .year()
                .month(.abbreviated)
                .day()
                .locale(locale)
        )
    }

    private static func axisDateText(
        _ date: Date,
        domain: ClosedRange<Date>,
        locale: Locale
    ) -> String {
        if StarHistoryChartLayoutPolicy.usesYearOnlyAxisLabels(domain: domain) {
            return date.formatted(.dateTime.year().locale(locale))
        }
        if StarHistoryChartLayoutPolicy.usesDayAxisLabels(domain: domain) {
            return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        }
        return date.formatted(.dateTime.year().month(.abbreviated).locale(locale))
    }

    /// README 卡片留有独立纵轴空间；常见量级保留完整数字，比过早缩成 K 更便于读值。
    private static func axisValueText(_ value: Double, locale: Locale) -> String {
        guard abs(value) < 100_000 else {
            return StarHistoryAxisValueFormatter.string(from: value, locale: locale)
        }
        return value.formatted(
            .number
                .precision(.fractionLength(0))
                .locale(locale)
        )
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// 同一个转义器同时用于文本和 attribute；固定模板不接受远端 HTML。
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
