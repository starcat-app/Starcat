//
//  OpenSSFScoreSheet.swift
//  Starcat
//
//  OpenSSF Scorecard 详情 sheet。
//
//  设计约束：
//  - 首次无缓存时只触发 Store 的非阻塞预拉，sheet 自身显示加载态，不同步等待网络。
//  - 雷达图过滤 score = -1 的无法评估项；明细列表仍展示它们，避免用户误以为缺项。
//  - 所有 SwiftUI 文案用 key；需要返回 String 的格式化走 `String.l10n`。
//

import SwiftUI

struct OpenSSFScoreSheet: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    private var store: OpenSSFScoreStore { dependencies.openSSFScoreStore }
    private var record: OpenSSFScoreRecord? { store.record(for: repo.id) }
    private var payload: OpenSSFScorePayload? {
        guard let data = record?.checksJSON else { return nil }
        return try? JSONDecoder().decode(OpenSSFScorePayload.self, from: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 560)
        .task(id: repo.id) {
            await store.loadCachedScores(for: [repo.id])
            if store.record(for: repo.id) == nil {
                store.prefetchIfNeeded(repo: repo)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("openssf.sheet.title")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(verbatim: repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await store.refresh(repo: repo, force: true) }
            } label: {
                Label("openssf.action.refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoading(repoId: repo.id))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.close")
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if let record, record.fetchStatus == .success, let payload {
            scoreContent(record: record, payload: payload)
        } else if let record {
            statusContent(record: record)
        } else if store.isLoading(repoId: repo.id) {
            loadingContent
        } else {
            loadingContent
        }
    }

    private func scoreContent(record: OpenSSFScoreRecord, payload: OpenSSFScorePayload) -> some View {
        let evaluated = payload.checks.filter(\.isEvaluated)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                scoreSummary(record: record)
                OpenSSFRadarChart(checks: evaluated)
                    .frame(height: 280)
                    .frame(maxWidth: .infinity)
                checksList(payload.checks)
            }
            .padding(20)
        }
    }

    private func scoreSummary(record: OpenSSFScoreRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(record.aggregateScore.map { String(format: "%.1f", $0) } ?? "N/A")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 3) {
                Text("openssf.score.aggregate")
                    .font(.headline)
                if let scoreDate = record.scoreDate {
                    Text(String(format: String.l10n("openssf.score.dateFormat"), scoreDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Link(destination: URL(string: "https://scorecard.dev/viewer/?uri=github.com/\(repo.owner)/\(repo.name)")!) {
                Label("openssf.action.openViewer", systemImage: "safari")
            }
        }
    }

    private func checksList(_ checks: [OpenSSFScoreCheck]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("openssf.checks.title")
                .font(.headline)

            ForEach(checks) { check in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(verbatim: check.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(check.isEvaluated ? String(format: "%.1f", check.score) : String.l10n("openssf.check.unavailable"))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let reason = check.reason, !reason.isEmpty {
                        Text(verbatim: reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func statusContent(record: OpenSSFScoreRecord) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(statusTitle(record.fetchStatus))
                .font(.headline)
            if let lastError = record.lastError, !lastError.isEmpty {
                Text(verbatim: lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("openssf.loading")
                .font(.headline)
            Text("openssf.loading.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func statusTitle(_ status: OpenSSFScoreFetchStatus) -> LocalizedStringKey {
        switch status {
        case .success: return "openssf.status.success"
        case .notIndexed: return "openssf.status.notIndexed"
        case .networkError: return "openssf.status.networkError"
        case .parseError: return "openssf.status.parseError"
        }
    }
}

private struct OpenSSFRadarChart: View {
    let checks: [OpenSSFScoreCheck]

    var body: some View {
        if checks.count >= 3 {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.38
                let count = checks.count

                for ring in 1...5 {
                    var path = Path()
                    let ringRadius = radius * CGFloat(ring) / 5
                    for index in 0..<count {
                        let point = point(index: index, count: count, center: center, radius: ringRadius)
                        index == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                }

                for index in 0..<count {
                    let end = point(index: index, count: count, center: center, radius: radius)
                    var axis = Path()
                    axis.move(to: center)
                    axis.addLine(to: end)
                    context.stroke(axis, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                }

                var valuePath = Path()
                for (index, check) in checks.enumerated() {
                    let normalized = max(0, min(check.score, 10)) / 10
                    let point = point(index: index, count: count, center: center, radius: radius * normalized)
                    index == 0 ? valuePath.move(to: point) : valuePath.addLine(to: point)
                }
                valuePath.closeSubpath()
                context.fill(valuePath, with: .color(.accentColor.opacity(0.22)))
                context.stroke(valuePath, with: .color(.accentColor.opacity(0.78)), lineWidth: 2)
            }
            .overlay(alignment: .bottom) {
                Text("openssf.chart.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("openssf.chart.notEnoughData")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func point(index: Int, count: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (Double(index) / Double(count)) * 2 * Double.pi - Double.pi / 2
        return CGPoint(
            x: center.x + CGFloat(cos(angle)) * radius,
            y: center.y + CGFloat(sin(angle)) * radius
        )
    }
}
