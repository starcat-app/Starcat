//
//  ReadmeStarHistoryHTMLRenderer.swift
//  Starcat
//
//  原型风格的 README Star History 卡片：仓库信息、全历史曲线、四项指标。
//  HTML 只来自固定模板；仓库文本和 JSON 属性统一转义。图形布局由受控 DOM 脚本
//  按容器宽度更新，完整序列仅供 hover/统计，折线仍最多使用 90 个绘制点。
//

import AppKit
import Foundation
import SwiftUI

/// 将不可变历史快照投影成 HTML；不触发网络请求，也不访问用户数据库。
@MainActor
enum ReadmeStarHistoryHTMLRenderer {
    static func render(
        snapshot: StarHistorySnapshot,
        model: StarHistoryChartRenderModel,
        repo: Repo,
        locale: Locale,
        now: Date = Date(),
        avatarDataURI: String? = nil
    ) -> String? {
        let points = snapshot.points.filter { $0.count >= 0 }.sorted { $0.date < $1.date }
        guard snapshot.range == .all, points.count >= 2, let first = points.first,
              let last = points.last, first.date < last.date else { return nil }
        let rendered = model.renderedPoints
        guard rendered.count >= 2 else { return nil }

        let createdAt = repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
        // 绘制与交互共用创建日起点；指标仍只接收原始 snapshot，补点不会成为增长基准。
        let plottingPoints = StarHistoryChartSeriesBuilder.addingCreationBaseline(
            to: points, range: .all, repositoryCreatedAt: createdAt
        )
        let metrics = ReadmeStarHistoryMetrics(snapshot: snapshot, createdAt: createdAt, now: now)
        let axis = ReadmeStarHistoryAxis(peak: points.map(\.count).max() ?? 0)
        let total = max(0, repo.starsCount)
        let totalText = compact(total, locale: locale)
        let totalFull = total.formatted(.number.locale(locale))
        let totalLabel = text("readme.starHistory.totalStars")
        let chartTitle = text("readme.starHistory.chartTitle")
        let source = text("readme.starHistory.estimateExplanation")
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
        let precisionHint = metrics.isEstimated ? String.l10n("readme.starHistory.estimateExplanation") : ""
        let growthHint = metrics.growth == nil ? String.l10n("readme.starHistory.insufficientHistory") : precisionHint
        let rateHint = metrics.growthRate == nil
            ? String.l10n(metrics.growth == nil ? "readme.starHistory.insufficientHistory" : "readme.starHistory.zeroBaseline")
            : precisionHint
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

        // 四列只显示数值和短标签；统计窗口、创建日及精度保留在提示里，避免窄栏出现第三行。
        let cardMetrics = [
            metric(icon: "chart.bar.fill", color: "green", value: dailyAverage, label: text("readme.starHistory.dailyAverage"),
                   hint: [String.l10n("readme.starHistory.dailyAverage"), dailyHint, growthPeriod, daysHint, growthHint].filter { !$0.isEmpty }.joined(separator: " · ")),
            metric(icon: "calendar", color: "purple", value: age, label: text("readme.starHistory.age"), hint: sinceDetail),
            metric(icon: "star.fill", color: "gold", value: growth, label: text("readme.starHistory.newStars"),
                   hint: [growthPeriod, growthHint].filter { !$0.isEmpty }.joined(separator: " · ")),
            metric(icon: "arrow.up.right", color: "pink", value: rate, label: text("readme.starHistory.growth"),
                   hint: [ratePeriod, fullRate, rateHint].filter { !$0.isEmpty }.joined(separator: " · "))
        ].joined(separator: "\n")

        let description = repo.description.flatMap { value -> String? in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "<p class=\"starcat-star-history-description\" title=\"\(escape(value))\">\(escape(value))</p>"
        } ?? ""
        // 本机快照写入时间不代表服务端数据更新；优先使用对应这批历史的 generatedAt。
        let generatedAt = snapshot.coverage?.generatedAt
            ?? points.filter { $0.source == .ghArchive }.compactMap(\.fetchedAt).max()
        let historyUpdated = format("readme.starHistory.updatedFormat", generatedAt.map { dateText($0, locale: locale) } ?? "—")
        // 只接收 App 已准备好的图片数据，避免 WebView 再发远程请求；缺图由 ViewModel 异步补齐。
        let avatarImage = avatarDataURI.map {
            "<img src=\"\(escape($0))\" alt=\"\" width=\"72\" height=\"72\" loading=\"eager\" decoding=\"sync\">"
        } ?? ""
        let chart = chartHTML(points: plottingPoints, rendered: rendered, axis: axis, locale: locale)

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
            <footer class="starcat-star-history-footer">
              <div class="starcat-star-history-source" title="\(source)">
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
        points: [StarHistoryPoint], rendered: [StarHistoryPoint], axis: ReadmeStarHistoryAxis, locale: Locale
    ) -> String {
        let width = 960.0, height = 310.0, left = 44.0, right = 14.0, top = 66.0, bottom = 30.0
        let start = points[0].date.timeIntervalSince1970
        let duration = max(1, points[points.count - 1].date.timeIntervalSince1970 - start)
        func x(_ point: StarHistoryPoint) -> Double { left + (point.date.timeIntervalSince1970 - start) / duration * (width - left - right) }
        func y(_ count: Int) -> Double { top + (1 - Double(count) / axis.maximum) * (height - top - bottom) }
        let coordinates = rendered.map { "\(decimal(x($0))),\(decimal(y($0.count)))" }.joined(separator: " ")
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
          data-step="\(axis.step)" data-locale="\(escape(locale.identifier.replacingOccurrences(of: "_", with: "-")))"
          data-estimated-label="\(text("readme.starHistory.estimated"))">
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

    private static func metric(icon symbol: String, color: String, value: String, label: String, hint: String) -> String {
        """
        <div class="starcat-star-history-metric" title="\(escape(hint))">
          <span class="starcat-star-history-metric-icon starcat-star-history-\(color)" aria-hidden="true">\(icon(symbol))</span>
          <div class="starcat-star-history-metric-copy"><strong>\(escape(value))</strong><span>\(label)</span></div>
        </div>
        """
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

    /// 只编码数字与精度标识；JS 通过 Intl 格式化选中点，无需为每个历史日生成 DOM。
    private static func encoded(_ points: [StarHistoryPoint]) -> String {
        let values = points.map { [$0.date.timeIntervalSince1970 * 1_000, Double($0.count), $0.precision == .snapshot ? 0.0 : 1.0] }
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
