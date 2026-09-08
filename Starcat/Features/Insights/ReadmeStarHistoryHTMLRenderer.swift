//
//  ReadmeStarHistoryHTMLRenderer.swift
//  Starcat
//
//  原型风格的 README Star History 卡片：仓库信息、全历史曲线、四项指标与成长时间线。
//  HTML 只来自固定模板；仓库文本和 JSON 属性统一转义。图形布局由受控 DOM 脚本
//  按容器宽度更新，完整序列仅供 hover/统计，折线仍最多使用 90 个绘制点。
//

import AppKit
import Foundation
import SwiftUI

/// 将不可变历史快照投影成 HTML；不触发网络请求，也不访问用户数据库。
@MainActor
enum ReadmeStarHistoryHTMLRenderer {
    /// 无可用缓存时使用固定结构占位，避免短 README 底部在网络等待期间完全空白。
    ///
    /// 骨架不包含仓库数据，也不触发图表脚本；外层 `aria-busy` 让辅助功能知道该区域
    /// 尚未就绪，内部纯装饰块从可访问性树中隐藏。
    static func renderLoading() -> String {
        let chartTitle = text("readme.starHistory.chartTitle")
        return """
        <section class="starcat-star-history starcat-star-history-loading" aria-label="\(chartTitle)" aria-busy="true">
          <div class="starcat-star-history-card starcat-star-history-skeleton" aria-hidden="true">
            <div class="starcat-star-history-skeleton-header">
              <span class="starcat-star-history-skeleton-block starcat-star-history-skeleton-avatar"></span>
              <div class="starcat-star-history-skeleton-copy">
                <span class="starcat-star-history-skeleton-block starcat-star-history-skeleton-kicker"></span>
                <span class="starcat-star-history-skeleton-block starcat-star-history-skeleton-title"></span>
                <span class="starcat-star-history-skeleton-block starcat-star-history-skeleton-description"></span>
                <span class="starcat-star-history-skeleton-block starcat-star-history-skeleton-tag"></span>
              </div>
              <span class="starcat-star-history-skeleton-block starcat-star-history-skeleton-total"></span>
            </div>
            <div class="starcat-star-history-skeleton-block starcat-star-history-skeleton-chart"></div>
            <div class="starcat-star-history-skeleton-metrics">
              <span class="starcat-star-history-skeleton-block"></span>
              <span class="starcat-star-history-skeleton-block"></span>
              <span class="starcat-star-history-skeleton-block"></span>
              <span class="starcat-star-history-skeleton-block"></span>
            </div>
            <div class="starcat-star-history-skeleton-block starcat-star-history-skeleton-journey"></div>
            <div class="starcat-star-history-skeleton-footer">
              <span class="starcat-star-history-skeleton-block"></span>
              <span class="starcat-star-history-skeleton-block"></span>
            </div>
          </div>
        </section>
        """
    }

    static func render(
        snapshot: StarHistorySnapshot,
        model: StarHistoryChartRenderModel,
        repo: Repo,
        locale: Locale,
        now: Date = Date(),
        avatarDataURI: String? = nil
    ) -> String? {
        let points = snapshot.points.filter { $0.count >= 0 }.sorted { $0.date < $1.date }
        let hasChart = points.count >= 2 && points.first!.date < points.last!.date && model.renderedPoints.count >= 2
        guard snapshot.range == .all, repo.starsCount > 0, hasChart else { return nil }

        let createdAt = repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
        let journey = ReadmeStarJourney(snapshot: snapshot, repo: repo)
        // 绘制与交互共用创建日起点；指标仍只接收原始 snapshot，补点不会成为增长基准。
        let plottingPoints = StarHistoryChartSeriesBuilder.addingCreationBaseline(
            to: points, range: .all, repositoryCreatedAt: createdAt
        )
        // 先识别语义事件再抽样，所有候选标注锚点都必须出现在最终折线上，且仍限制在 90 点内。
        let anchorIDs = Set(journey.chartEvents.compactMap { $0.point?.id })
        let anchors = plottingPoints.filter { anchorIDs.contains($0.id) }
        let baseIDs = Set(model.renderedPoints.map(\.id))
        let missingAnchors = anchors.filter { !baseIDs.contains($0.id) }
        var rendered = model.renderedPoints
        if rendered.count + missingAnchors.count > StarHistoryChartSeriesBuilder.allRangePointLimit {
            rendered = StarHistoryChartSeriesBuilder.renderedPoints(
                points, range: .all, repositoryCreatedAt: createdAt,
                maximumPointCount: StarHistoryChartSeriesBuilder.allRangePointLimit - anchors.count
            )
        }
        let renderedIDs = Set(rendered.map(\.id))
        rendered = (rendered + anchors.filter { !renderedIDs.contains($0.id) }).sorted { $0.date < $1.date }
        let metrics = ReadmeStarHistoryMetrics(snapshot: snapshot, createdAt: createdAt, now: now)
        let axis = ReadmeStarHistoryAxis(peak: points.map(\.count).max() ?? 0)
        let total = max(0, repo.starsCount)
        let totalText = compact(total, locale: locale)
        let totalFull = total.formatted(.number.locale(locale))
        let totalLabel = text("readme.starHistory.totalStars")
        let chartTitle = text("readme.starHistory.chartTitle")
        let updated = repo.cachedAt.flatMap(ISO8601DateFormatter.githubDate(from:))
            .map { format("readme.starHistory.updatedFormat", dateText($0, locale: locale)) }
        let totalHint = [totalFull, updated].compactMap { $0 }.joined(separator: " · ")
        let growth = metrics.growth.map { signed($0, locale: locale) } ?? "—"
        let dailyAverage = metrics.dailyAverage.map { value in
            let number = abs(value) >= 1_000
                ? StarHistoryAxisValueFormatter.string(from: value, locale: locale)
                : value.formatted(.number.precision(.fractionLength(0...(abs(value) < 1 ? 2 : 1))).locale(locale))
            return (value > 0 ? "+" : "") + number
        } ?? "—"
        let rate = metrics.growthRate.map { value in
            // 高增长率无需在小卡里保留小数；超过 1,000% 时继续沿用 K / M，完整值放入提示。
            if abs(value) >= 10 {
                return (value > 0 ? "+" : "") + StarHistoryAxisValueFormatter.string(from: value * 100, locale: locale) + "%"
            }
            return value.formatted(.percent.precision(.fractionLength(0...(abs(value) >= 1 ? 0 : 1))).sign(strategy: .always()).locale(locale))
        } ?? "—"
        let fullRate = metrics.growthRate.map {
            $0.formatted(.percent.precision(.fractionLength(0...2)).sign(strategy: .always()).locale(locale))
        } ?? ""
        let growthPeriod = String.l10n(metrics.sinceCreated
            ? "readme.starHistory.growthSinceCreated" : "readme.starHistory.growth90Days")
        let ratePeriod = String.l10n(metrics.sinceCreated
            ? "readme.starHistory.rateSinceCreated" : "readme.starHistory.rate90Days")
        let growthHint = metrics.growth == nil ? String.l10n("readme.starHistory.insufficientHistory") : ""
        let rateHint = metrics.growthRate == nil
            ? String.l10n(metrics.growth == nil ? "readme.starHistory.insufficientHistory" : "readme.starHistory.zeroBaseline")
            : ""
        let daysHint = metrics.periodDays.map {
            format("readme.starHistory.daysFormat", $0.formatted(.number.locale(locale)))
        } ?? ""
        let dailyHint = metrics.dailyAverage.map {
            $0.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        } ?? String.l10n("readme.starHistory.insufficientHistory")
        let age = metrics.ageDays.map {
            format("readme.starHistory.daysCompactFormat", $0.formatted(.number.locale(locale)))
        } ?? "—"
        let sinceDetail = createdAt.map { dateText($0, locale: locale) } ?? text("readme.starHistory.unknownCreated")

        let miniatures = metricMiniatures(points: points, metrics: metrics, createdAt: createdAt)
        // 两行读数始终保留；宽卡片在右侧补充趋势图，窄栏由 CSS 隐藏，不增加卡片高度。
        let cardMetrics = [
            metric(icon: "chart.bar.fill", color: "green", value: dailyAverage, label: text("readme.starHistory.dailyAverage"),
                   hint: [String.l10n("readme.starHistory.dailyAverage"), dailyHint, growthPeriod, daysHint, growthHint].filter { !$0.isEmpty }.joined(separator: "\n"), graphic: miniatures.daily),
            metric(icon: "calendar", color: "purple", value: age, label: text("readme.starHistory.age"), hint: sinceDetail, graphic: miniatures.age),
            metric(icon: "star.fill", color: "gold", value: growth, label: text("readme.starHistory.newStars"),
                   hint: [growthPeriod, growthHint].filter { !$0.isEmpty }.joined(separator: "\n"), graphic: miniatures.growth),
            metric(icon: "arrow.up.right", color: "pink", value: rate, label: text("readme.starHistory.growth"),
                   hint: [ratePeriod, fullRate, rateHint].filter { !$0.isEmpty }.joined(separator: "\n"), graphic: miniatures.rate)
        ].joined(separator: "\n")

        let description = repo.description.flatMap { value -> String? in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "<p class=\"starcat-star-history-description\" title=\"\(escape(value))\">\(escape(value))</p>"
        } ?? ""
        // 官方历史的 generatedAt 才代表这批曲线的更新时间，Repo metadata 时间不能替代。
        let generatedAt = snapshot.coverage?.generatedAt
            ?? points.filter { $0.source == .githubHistory }.compactMap(\.fetchedAt).max()
        let historyUpdated = format("readme.starHistory.updatedFormat", generatedAt.map { dateText($0, locale: locale) } ?? "—")
        // 只接收 App 已准备好的图片数据，避免 WebView 再发远程请求；缺图由 ViewModel 异步补齐。
        let avatarImage = avatarDataURI.map {
            "<img src=\"\(escape($0))\" alt=\"\" width=\"72\" height=\"72\" loading=\"eager\" decoding=\"sync\">"
        } ?? ""
        let chart = hasChart ? chartHTML(points: plottingPoints, rendered: rendered, axis: axis, locale: locale,
                                        annotations: chartAnnotations(journey, points: plottingPoints, locale: locale)) : ""

        return """
        <section class="starcat-star-history" aria-label="\(chartTitle)">
          <div class="starcat-star-history-card">
            <header class="starcat-star-history-card-header">
              <div class="starcat-star-history-repository">
                <span class="starcat-star-history-avatar" aria-hidden="true">
                  \(avatarImage)
                </span>
                <div class="starcat-star-history-card-copy">
                  <span class="starcat-star-history-card-kicker">\(icon("github"))\(chartTitle)</span>
                  <h3 title="\(escape(repo.fullName))">\(escape(repo.fullName))</h3>
                  \(description)
                  \(tags(repo: repo))
                </div>
              </div>
              <div class="starcat-star-history-current" title="\(escape(totalHint))" aria-label="\(totalLabel) \(escape(totalFull))">
                <div class="starcat-star-history-current-value">
                  <span class="starcat-star-history-current-star">\(icon("star.fill"))</span>
                  <strong>\(escape(totalText))</strong>
                </div>
                <span class="starcat-star-history-current-label">\(totalLabel)</span>
              </div>
            </header>
            \(chart)
            <div class="starcat-star-history-metrics">\(cardMetrics)</div>
            \(journeyHTML(journey, locale: locale))
            <footer class="starcat-star-history-footer">
              <div class="starcat-star-history-source">
                \(icon("clock"))<span>\(escape(historyUpdated))</span>
              </div>
              <div class="starcat-star-history-footer-actions">
                <span class="starcat-star-history-attribution">\(icon("sparkles"))\(text("readme.starHistory.poweredByPrefix")) <strong>Starcat</strong></span>
              </div>
            </footer>
          </div>
        </section>
        """
    }

    /// 首屏 SVG 已包含完整折线；受控脚本会按实际 CSS 宽度重排坐标与标注，保持文字可读。
    private static func chartHTML(
        points: [StarHistoryPoint], rendered: [StarHistoryPoint], axis: ReadmeStarHistoryAxis, locale: Locale,
        annotations: String
    ) -> String {
        let width = 960.0, height = 310.0, left = 44.0, right = 14.0, top = 66.0, bottom = 30.0
        let start = points[0].date.timeIntervalSince1970
        let duration = max(1, points[points.count - 1].date.timeIntervalSince1970 - start)
        func x(_ point: StarHistoryPoint) -> Double { left + (point.date.timeIntervalSince1970 - start) / duration * (width - left - right) }
        func y(_ count: Int) -> Double { top + (1 - Double(count) / axis.maximum) * (height - top - bottom) }
        // 与时间线片段一样，坐标拼接也显式保留 String，避免落入 GRDB 的 SQL 字面量重载。
        let coordinates: String = rendered.map { point -> String in
            "\(decimal(x(point))),\(decimal(y(point.count)))"
        }.joined(separator: " ")
        let base = height - bottom
        let area = "\(decimal(x(rendered[0]))),\(decimal(base)) \(coordinates) \(decimal(x(rendered[rendered.count - 1]))),\(decimal(base))"
        let ticks: String = axis.ticks.map { value -> String in
            let tickY = top + (1 - value / axis.maximum) * (height - top - bottom)
            return """
            <g><line class="starcat-star-history-grid starcat-star-history-grid-horizontal" x1="\(left)" x2="\(width - right)" y1="\(tickY)" y2="\(tickY)"></line><text class="starcat-star-history-axis starcat-star-history-axis-y" x="\(left - 10)" y="\(tickY)" text-anchor="end" dominant-baseline="middle">\(escape(StarHistoryAxisValueFormatter.string(from: value, locale: locale)))</text></g>
            """
        }.joined()
        return """
        <div class="starcat-star-history-chart" tabindex="0" role="slider" aria-label="\(text("readme.starHistory.exploreChart"))" aria-valuemin="0" aria-valuemax="\(points.count - 1)" aria-valuenow="\(points.count - 1)"
          data-points="\(encoded(points))" data-rendered="\(encoded(rendered))" data-maximum="\(axis.maximum)"
          data-step="\(axis.step)" data-annotations="\(annotations)" data-locale="\(escape(locale.identifier.replacingOccurrences(of: "_", with: "-")))">
          <svg viewBox="0 0 960 310" aria-hidden="true">
            <defs><linearGradient id="starcat-history-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" class="starcat-star-history-gradient-top"></stop><stop offset="100%" class="starcat-star-history-gradient-bottom"></stop></linearGradient></defs>
            <g class="starcat-star-history-y-ticks">\(ticks)</g>
            <g class="starcat-star-history-x-ticks"></g>
            <polygon class="starcat-star-history-area" points="\(area)"></polygon>
            <polyline class="starcat-star-history-line" points="\(coordinates)"></polyline>
            <g class="starcat-star-history-markers"></g>
            <line class="starcat-star-history-crosshair" style="display:none"></line>
            <circle class="starcat-star-history-hover-point" r="5" style="display:none"></circle>
          </svg>
          <div class="starcat-star-history-callouts" aria-hidden="true"></div>
          <div class="starcat-star-history-tooltip" role="tooltip" hidden></div>
        </div>
        """
    }

    /// 时间线均匀分列，data-rank 仅控制窄栏隐藏顺序，日期与阈值不会因窗口宽度而改变。
    private static func journeyHTML(_ journey: ReadmeStarJourney, locale: Locale) -> String {
        let chronological = journey.rankedEvents.enumerated().sorted { lhs, rhs in
            if lhs.offset == rhs.offset { return false }
            if lhs.element.kind == .created || rhs.element.kind == .current { return true }
            if lhs.element.kind == .current || rhs.element.kind == .created { return false }
            if lhs.element.date == rhs.element.date { return lhs.offset < rhs.offset }
            return (lhs.element.date ?? .distantPast) < (rhs.element.date ?? .distantPast)
        }
        // 明确限定 HTML 片段为 String，避免无参 joined() 被推断为 GRDB 的 SQL 拼接重载。
        let nodes: String = chronological.map { rank, event -> String in
            // Current 保留真实日期与末位身份，但不生成任何可见文案或原生悬浮 title。
            // 不能再把它作为带文案的倒数第二点，并另造一个不对应历史数据的终点。
            if event.kind == .current {
                let date = event.date.map { ISO8601DateFormatter.shared.string(from: $0) } ?? ""
                return """
                <li class="starcat-star-journey-node starcat-star-journey-current" data-rank="\(rank)" data-date="\(escape(date))">
                  <span class="starcat-star-journey-dot" aria-hidden="true"></span>
                </li>
                """
            }
            let subtitle = eventSubtitle(event, locale: locale)
            return """
            <li class="starcat-star-journey-node starcat-star-journey-\(event.kind.rawValue)" data-rank="\(rank)" title="\(escape(eventHint(event, currentCount: journey.currentCount, locale: locale)))">
              <span class="starcat-star-journey-dot" aria-hidden="true"></span>
              <div class="starcat-star-journey-copy">
                <time>\(escape(event.date.map { dateText($0, locale: locale) } ?? "—"))</time>
                <strong>\(escape(eventTitle(event, currentCount: journey.currentCount, locale: locale)))</strong>
                \(subtitle.map { "<span>\(escape($0))</span>" } ?? "")
              </div>
            </li>
            """
        }.joined(separator: "")
        return """
        <section class="starcat-star-journey" aria-label="\(text("readme.starJourney.title"))">
          <h4>\(text("readme.starJourney.title"))</h4>
          <ol class="starcat-star-journey-track" style="--journey-columns:\(max(1, chronological.count - 1))">\(nodes)</ol>
        </section>
        """
    }

    private static func eventTitle(_ event: ReadmeStarJourney.Event, currentCount: Int, locale: Locale) -> String {
        switch event.kind {
        case .created: return String.l10n("readme.starJourney.created")
        case .firstRecorded: return String.l10n("readme.starJourney.firstRecorded")
        case .milestone: return format("readme.starJourney.reachedFormat", compact(event.threshold ?? 0, locale: locale))
        case .bestDay: return String.l10n("readme.starJourney.bestDay")
        case .bestWeek: return String.l10n("readme.starJourney.bestWeek")
        case .spike: return String.l10n("readme.starJourney.spike")
        case .current: return format("readme.starJourney.starsFormat", compact(currentCount, locale: locale))
        }
    }

    private static func eventSubtitle(_ event: ReadmeStarJourney.Event, locale: Locale) -> String? {
        if event.kind == .current { return String.l10n("readme.starJourney.current") }
        guard let growth = event.growth else { return nil }
        return format(event.kind == .bestDay ? "readme.starJourney.growthDayFormat" : "readme.starJourney.growthWeekFormat",
                      compact(growth, locale: locale))
    }

    /// 悬停内容按字段提供，避免把读数、日期和事件解释重复拼成一整段文字。
    private static func eventRows(_ event: ReadmeStarJourney.Event, currentCount: Int, locale: Locale) -> [[String: String]] {
        // 当前点只显示读数和日期，同点的附加事件不再进入这个提示框。
        guard event.kind != .current else { return [] }
        var rows = [["label": String.l10n("readme.starJourney.tooltip.event"),
                     "value": eventTitle(event, currentCount: currentCount, locale: locale)]]
        if event.threshold != nil, let previous = event.previous {
            rows.append(["label": String.l10n("readme.starJourney.tooltip.previous"),
                         "value": format("readme.starJourney.starsFormat", previous.count.formatted(.number.locale(locale))),
                         "note": dateText(previous.date, locale: locale)])
        }
        if let growth = event.growth {
            rows.append(["label": String.l10n("readme.starHistory.newStars"),
                         "value": format("readme.starJourney.growthDayFormat", growth.formatted(.number.locale(locale)))])
        }
        if let start = event.windowStart, let date = event.date {
            rows.append(["label": String.l10n("readme.starJourney.tooltip.period"),
                         "value": dateText(start, locale: locale) + " – " + dateText(date, locale: locale)])
        }
        return rows
    }

    /// 原生 title 也按行组织；只说明事件含义，不重复曲线已有的数值或添加精度文案。
    private static func eventHint(_ event: ReadmeStarJourney.Event, currentCount: Int, locale: Locale) -> String {
        var parts = [eventTitle(event, currentCount: currentCount, locale: locale)]
        if let date = event.date { parts.append(dateText(date, locale: locale)) }
        for row in eventRows(event, currentCount: currentCount, locale: locale).dropFirst() {
            parts.append([row["label"], row["value"], row["note"]].compactMap { $0 }.joined(separator: " · "))
        }
        if event.kind == .firstRecorded { parts.append(String.l10n("readme.starJourney.firstRecordedHint")) }
        return parts.joined(separator: "\n")
    }

    /// Chart 独立筛选最多四个事件。气泡显示原点读数，跨阈值语义保留在交互提示里。
    private static func chartAnnotations(_ journey: ReadmeStarJourney, points: [StarHistoryPoint], locale: Locale) -> String {
        var annotations: [[String: Any]] = []
        var used = Set<Int>()
        for event in journey.chartEvents {
            guard let point = event.point, let index = points.firstIndex(where: { $0.id == point.id }),
                  used.insert(index).inserted else { continue }
            let subtitle = event.kind == .current ? nil : eventSubtitle(event, locale: locale)
            annotations.append([
                "index": index, "kind": event.kind.rawValue,
                "title": event.kind == .spike ? String.l10n("readme.starJourney.spike") : compact(point.count, locale: locale),
                "subtitle": subtitle ?? "", "rows": eventRows(event, currentCount: journey.currentCount, locale: locale)
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: annotations),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return escape(json)
    }

    private static func metric(icon symbol: String, color: String, value: String, label: String, hint: String, graphic: String) -> String {
        """
        <div class="starcat-star-history-metric" title="\(escape(hint))">
          <span class="starcat-star-history-metric-icon starcat-star-history-\(color)" aria-hidden="true">\(icon(symbol))</span>
          <div class="starcat-star-history-metric-copy"><strong>\(escape(value))</strong><span>\(label)</span></div>
          \(graphic)
        </div>
        """
    }

    /// 宽卡片的轻量示意图与主指标共用统计窗口。只读现有记录，不补日数据或发起请求。
    /// 创建时长使用日历刻度；其余图形缺少有效历史时省略，避免用随机曲线暗示增长。
    private static func metricMiniatures(
        points: [StarHistoryPoint], metrics: ReadmeStarHistoryMetrics, createdAt: Date?
    ) -> (daily: String, age: String, growth: String, rate: String) {
        func svg(_ body: String, color: String) -> String {
            "<svg class=\"starcat-star-history-miniature starcat-star-history-miniature-\(color)\" viewBox=\"0 0 96 36\" aria-hidden=\"true\" focusable=\"false\">\(body)</svg>"
        }
        let calendarTicks: String = (0..<7).map { index -> String in
            let x = 6 + index * 14
            return "<path d=\"M\(x) 12V24\" opacity=\"0.4\"/>"
        }.joined(separator: "")
        let age = metrics.ageDays == nil ? "" : svg(
            "<path d=\"M6 18H90\" opacity=\"0.35\"/>" + calendarTicks
                + "<circle cx=\"6\" cy=\"18\" r=\"3\"/><circle cx=\"90\" cy=\"18\" r=\"4\"/>", color: "purple")
        guard let latest = points.last, let growth = metrics.growth else { return ("", age, "", "") }
        let start = metrics.sinceCreated ? (createdAt ?? latest.date) : latest.date.addingTimeInterval(-90 * 86_400)
        let period = points.filter { $0.date >= start }
        guard period.count >= 2 else { return ("", age, "", "") }
        let baseline = latest.count - growth
        let sampled = StarHistoryChartSeriesBuilder.renderedPoints(
            period, range: .all, repositoryCreatedAt: nil, maximumPointCount: 24
        )
        // 小图不需要坐标标签，仍按真实日期定位；零基线保留，负增长不会被裁成上升形状。
        func line(divisor: Double, color: String) -> String {
            let values = sampled.map { Double($0.count - baseline) / divisor }
            let lower = min(0, values.min() ?? 0), upper = max(0, values.max() ?? 0)
            let span = max(0.0001, upper - lower)
            let duration = max(1, latest.date.timeIntervalSince(start))
            let coordinates: String = zip(sampled, values).map { point, value -> String in
                let x = 4 + point.date.timeIntervalSince(start) / duration * 88
                let y = 31 - (value - lower) / span * 26
                return "\(decimal(x)),\(decimal(y))"
            }.joined(separator: " ")
            return svg("<polyline points=\"\(coordinates)\" fill=\"none\"/>", color: color)
        }
        // 柱高是相邻观测间的日均净变化；来源交接不参与，不能被显示为增长尖峰。
        let averages: [Double] = zip(period, period.dropFirst()).compactMap { previous, next in
            let days = next.date.timeIntervalSince(previous.date) / 86_400
            guard days > 0, previous.source == next.source, previous.precision == next.precision else { return nil }
            return Double(next.count - previous.count) / days
        }
        let bucketCount = min(12, averages.count)
        let buckets: [Double] = (0..<bucketCount).map { index in
            let start = index * averages.count / bucketCount
            let end = (index + 1) * averages.count / bucketCount
            return averages[start..<end].reduce(0, +) / Double(end - start)
        }
        let peak = max(1, buckets.map { abs($0) }.max() ?? 0)
        let hasNegative = buckets.contains { $0 < 0 }
        let zero = hasNegative ? 18.0 : 32.0
        let bars: String = buckets.enumerated().map { index, value -> String in
            let height = max(1, abs(value) / peak * (hasNegative ? 13 : 27))
            let x = 4 + Double(index) * 88 / Double(bucketCount)
            return "<rect x=\"\(decimal(x))\" y=\"\(decimal(value < 0 ? zero : zero - height))\" width=\"\(decimal(88 / Double(bucketCount) - 3))\" height=\"\(decimal(height))\" rx=\"1\" stroke=\"none\"/>"
        }.joined(separator: "")
        return (bars.isEmpty ? "" : svg(bars, color: "green"), age, line(divisor: 1, color: "gold"),
                metrics.growthRate != nil && baseline > 0 ? line(divisor: Double(baseline), color: "pink") : "")
    }

    private static func tags(repo: Repo) -> String {
        var chips: [String] = []
        if let language = repo.language, !language.isEmpty {
            let color = NSColor(LanguageColor.color(for: language)).usingColorSpace(.sRGB) ?? .systemBlue
            let hex = String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            chips.append("<span class=\"starcat-star-history-tag starcat-star-history-tag-language\" title=\"\(escape(language))\"><i style=\"background:\(hex)\"></i><span>\(escape(language))</span></span>")
        }
        let topics = repo.topicsArray.filter { !$0.isEmpty && $0.caseInsensitiveCompare(repo.language ?? "") != .orderedSame }
        for (index, topic) in topics.prefix(3).enumerated() {
            let color = ["purple", "pink", "green"][index]
            chips.append("<span class=\"starcat-star-history-tag starcat-star-history-tag-topic\" title=\"\(escape(topic))\"><i class=\"starcat-star-history-dot-\(color)\"></i><span>\(escape(topic))</span></span>")
        }
        if !topics.isEmpty {
            let remaining = max(0, topics.count - 3)
            chips.append("<span class=\"starcat-star-history-tag starcat-star-history-tag-more\" title=\"\(escape(topics.dropFirst(3).joined(separator: ", ")))\"\(remaining == 0 ? " hidden" : "")>+\(remaining)</span>")
        }
        guard !chips.isEmpty else { return "" }
        // 保留全部名称供布局计算隐藏数和 tooltip；最多创建三个 Topic 节点，避免宽度变化时重建列表。
        let topicNames = (try? JSONEncoder().encode(topics)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "<div class=\"starcat-star-history-tags\" data-topics=\"\(escape(topicNames))\">\(chips.joined())</div>"
    }

    /// 只编码日期与星标数；JS 通过 Intl 格式化选中点，无需为每个历史日生成 DOM。
    private static func encoded(_ points: [StarHistoryPoint]) -> String {
        let values = points.map { [$0.date.timeIntervalSince1970 * 1_000, Double($0.count)] }
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return escape(json)
    }

    private static func compact(_ value: Int, locale: Locale) -> String {
        StarHistoryAxisValueFormatter.string(from: Double(value), locale: locale)
    }

    private static func signed(_ value: Int, locale: Locale) -> String {
        (value > 0 ? "+" : "") + compact(value, locale: locale)
    }

    private static func text(_ key: String) -> String { escape(String.l10n(key)) }
    private static func format(_ key: String, _ value: String) -> String { String(format: String.l10n(key), value) }

    private static func dateText(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// 系统符号和已有 GitHub 资产转成 alpha mask，CSS 统一控制主题色；固定小集合只栅格化一次。
    private static var iconURLs: [String: String] = [:]
    private static func icon(_ name: String) -> String {
        if iconURLs[name] == nil {
            let source = name == "github" ? NSImage(named: "github") : NSImage(systemSymbolName: name, accessibilityDescription: nil)
            if let source {
                let canvas = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                    let ratio = min(rect.width / source.size.width, rect.height / source.size.height)
                    let size = NSSize(width: source.size.width * ratio, height: source.size.height * ratio)
                    source.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                          width: size.width, height: size.height))
                    return true
                }
                if let tiff = canvas.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    iconURLs[name] = "data:image/png;base64," + png.base64EncodedString()
                }
            }
        }
        guard let url = iconURLs[name] else { return "" }
        return "<span class=\"starcat-star-history-icon\" aria-hidden=\"true\" style=\"-webkit-mask-image:url('\(url)')\"></span>"
    }

    /// 同时用于文本和 attribute；远端描述、Topics 和名称只能作为纯文本进入模板。
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
