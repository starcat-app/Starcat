//
//  StarHistoryChartView.swift
//  Starcat
//
//  Star 历史曲线的独立渲染视图与不可变渲染模型。
//
//  关键约束：
//  - 原始历史只在 Snapshot 更新或范围切换时完成抽稀和渲染建模，滚动重绘不重复做 O(n) 处理。
//  - Hover 只在跨越最近数据点时写状态，不把鼠标每个像素都写进 SwiftUI 状态树。
//  - 导出图片复用相同渲染模型，但完全不注册 Hover，避免截入瞬时浮层或触发额外布局。
//

import AppKit
import Charts
import SwiftUI

struct StarHistoryChartRenderModel: Equatable, Sendable {
    let range: StarHistoryRange
    let renderedPoints: [StarHistoryPoint]
    let landmarks: [StarHistoryPoint]
    let xDomain: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    let xAxisDates: [Date]

    static let empty: StarHistoryChartRenderModel = {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return StarHistoryChartRenderModel(
            range: .oneYear,
            renderedPoints: [],
            landmarks: [],
            xDomain: start...start.addingTimeInterval(86_400),
            yDomain: 0...1,
            xAxisDates: []
        )
    }()

    init(
        points: [StarHistoryPoint],
        range: StarHistoryRange,
        repositoryCreatedAt: Date?,
        now: Date = Date()
    ) {
        let renderedPoints = StarHistoryChartSeriesBuilder.renderedPoints(
            points,
            range: range,
            repositoryCreatedAt: repositoryCreatedAt
        )
        let xDomain = StarHistoryChartLayoutPolicy.xDomain(
            range: range,
            repositoryCreatedAt: repositoryCreatedAt,
            points: points,
            now: now
        )

        self.range = range
        self.renderedPoints = renderedPoints
        landmarks = StarHistoryChartSeriesBuilder.landmarkPoints(in: renderedPoints)
        self.xDomain = xDomain
        yDomain = StarHistoryChartLayoutPolicy.yDomain(range: range, points: points)
        xAxisDates = StarHistoryChartLayoutPolicy.xAxisDates(domain: xDomain, range: range)
    }

    private init(
        range: StarHistoryRange,
        renderedPoints: [StarHistoryPoint],
        landmarks: [StarHistoryPoint],
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
        xAxisDates: [Date]
    ) {
        self.range = range
        self.renderedPoints = renderedPoints
        self.landmarks = landmarks
        self.xDomain = xDomain
        self.yDomain = yDomain
        self.xAxisDates = xAxisDates
    }
}

struct StarHistoryChartView: View {
    let model: StarHistoryChartRenderModel
    let interactionEnabled: Bool
    let accessibilityValue: String
    let height: CGFloat

    @State private var selectedPointID: String?

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    private var selectedPoint: StarHistoryPoint? {
        guard interactionEnabled, let selectedPointID else { return nil }
        return model.renderedPoints.first { $0.id == selectedPointID }
    }

    var body: some View {
        Chart {
            historyMarks
            landmarkMarks
            if let selectedPoint {
                selectionMarks(selectedPoint)
            }
        }
        .chartXAxis {
            AxisMarks(values: model.xAxisDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(verbatim: axisLabel(date))
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                }
                AxisTick(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.25))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { axisValue in
                AxisValueLabel {
                    if let value = axisValue.as(Int.self).map(Double.init)
                        ?? axisValue.as(Double.self) {
                        Text(verbatim: StarHistoryAxisValueFormatter.string(from: value, locale: locale))
                            .font(interfaceScale.font(.captionSmall))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
            }
        }
        .chartYScale(domain: model.yDomain)
        .chartXScale(
            domain: model.xDomain,
            range: .plotDimension(startPadding: 10, endPadding: 10)
        )
        .chartOverlay { proxy in
            if interactionEnabled {
                GeometryReader { geometry in
                    selectionOverlay(proxy: proxy, geometry: geometry)
                }
            }
        }
        .frame(height: height)
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("insights.repo.section.stars"))
        .accessibilityValue(Text(accessibilityValue))
    }

    /// `chartXSelection` 会为鼠标每个像素写入一个 Date。这里先映射到最近数据点，
    /// 只有点 ID 真正变化时才更新状态，因此在洞察页滚动经过图表时不会持续重建 Marks。
    private func selectionOverlay(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        ZStack {
            if let point = selectedPoint,
               let plotAnchor = proxy.plotFrame {
                let plot = geometry[plotAnchor]
                if let xInPlot = proxy.position(forX: point.date) {
                    let lineX = plot.origin.x + xInPlot
                    Path { path in
                        path.move(to: CGPoint(x: lineX, y: plot.minY))
                        path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
                    }
                    .stroke(
                        Color.secondary.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )

                    let tooltipWidth: CGFloat = 210
                    let clampedX = min(
                        max(lineX, plot.minX + tooltipWidth / 2),
                        plot.maxX - tooltipWidth / 2
                    )
                    selectionAnnotation(point)
                        .position(x: clampedX, y: plot.minY + 18)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard let plotAnchor = proxy.plotFrame else {
                    updateSelection(nil)
                    return
                }
                let plot = geometry[plotAnchor]
                guard plot.contains(location),
                      let date: Date = proxy.value(atX: location.x - plot.minX)
                else {
                    updateSelection(nil)
                    return
                }
                updateSelection(
                    StarHistoryDisplayPolicy.selectedPoint(
                        in: model.renderedPoints,
                        selectedDate: date
                    )?.id
                )
            case .ended:
                updateSelection(nil)
            }
        }
    }

    private func updateSelection(_ pointID: String?) {
        guard selectedPointID != pointID else { return }
        selectedPointID = pointID
    }

    private func selectionAnnotation(_ point: StarHistoryPoint) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: fullDate(point.date))
            Text("·")
            Text(point.count.formatted(.number.locale(locale)))
                .monospacedDigit()
        }
        .font(interfaceScale.font(.captionSmall, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
    }

    /// 数据来源与精度仍保留在模型中供统计和诊断使用，但趋势本身只表达 Stars 数量变化。
    /// 使用单一 series 和统一实线后，Swift Charts 会自然连接全部抽稀点，不再需要桥接 Mark。
    private var historyMarks: some ChartContent {
        ForEach(model.renderedPoints) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Stars", point.count),
                series: .value("Series", "Star History")
            )
            .foregroundStyle(Color.blue)
            .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.linear)
        }
    }

    private var landmarkMarks: some ChartContent {
        ForEach(model.landmarks) { point in
            PointMark(
                x: .value("Date", point.date),
                y: .value("Stars", point.count)
            )
            .foregroundStyle(Color.blue)
            .symbolSize(28)
        }
    }

    @ChartContentBuilder
    private func selectionMarks(_ point: StarHistoryPoint) -> some ChartContent {
        PointMark(
            x: .value("Date", point.date),
            y: .value("Stars", point.count)
        )
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        .symbolSize(70)

        PointMark(
            x: .value("Date", point.date),
            y: .value("Stars", point.count)
        )
        .foregroundStyle(Color.blue)
        .symbolSize(30)
    }

    private func axisLabel(_ date: Date) -> String {
        switch model.range {
        case .threeMonths:
            return date.formatted(
                Date.FormatStyle().month(.abbreviated).day().locale(locale)
            )
        case .oneYear:
            return date.formatted(
                Date.FormatStyle().year().month(.abbreviated).locale(locale)
            )
        case .all:
            if StarHistoryChartLayoutPolicy.usesDayAxisLabels(domain: model.xDomain) {
                return date.formatted(
                    Date.FormatStyle().month(.abbreviated).day().locale(locale)
                )
            }
            if !StarHistoryChartLayoutPolicy.usesYearOnlyAxisLabels(domain: model.xDomain) {
                return date.formatted(
                    Date.FormatStyle().year().month(.abbreviated).locale(locale)
                )
            }
            return date.formatted(Date.FormatStyle().year().locale(locale))
        }
    }

    private func fullDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().year().month().day().locale(locale))
    }
}
