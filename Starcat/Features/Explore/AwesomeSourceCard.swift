//
//  AwesomeSourceCard.swift
//  Starcat
//
//  来源选择 Sheet 的固定三列 Repo 风格卡片。
//

import AppKit
import SwiftUI

/// 用稳定高度和克制的胶囊元数据承载来源仓库事实，避免长标题或同步状态改变网格节奏。
struct AwesomeSourceCard: View {
    let source: AwesomeSource
    let isSelected: Bool
    let hasRefreshError: Bool
    let parseState: AwesomeCustomSourceParseState?
    let onToggle: () -> Void
    let onRetry: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var isHovering = false
    @State private var logoTint: Color?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    repositoryDescription
                    repositoryMetrics
                    languageBar
                    Divider()
                    footer
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // 固定高度与三列网格共同保证搜索、勾选和刷新时卡片位置不跳动。
                .frame(height: 226, alignment: .topLeading)
                .background(cardBackground)
                .overlay(cardBorder)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(source.isAvailable ? 1 : 0.62)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!source.isAvailable)
            .onHover { isHovering = $0 }
            .accessibilityLabel(Text(source.displayName))
            .accessibilityValue(Text(LocalizedStringKey(
                isSelected ? "awesome.sources.selected" : "awesome.sources.notSelected"
            )))

            HStack(spacing: 7) {
                if parseState?.phase == .failed, let onRetry {
                    SyncIconButton(
                        isRefreshing: false,
                        tooltip: String.l10n("action.retry"),
                        action: onRetry
                    )
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
                    .help(parseState?.errorMessage ?? String.l10n("action.retry"))
                }

                Link(destination: source.repoURL) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 27, height: 27)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(source.repoFullName)
                .accessibilityLabel(Text(source.repoFullName))

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 27, height: 27)

                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 27, height: 27)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(Text("awesome.sources.removeCustom"))
                    .accessibilityLabel(Text("awesome.sources.removeCustom"))
                }
            }
            .padding(11)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.displayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(source.repoFullName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if source.featured {
                    capsule(systemImage: "sparkles", text: String.l10n("awesome.sources.featured"))
                }
            }
            Spacer(minLength: 8)
            AwesomeSourceLogo(source: source, size: 54) { image in
                // 卡片色彩来自实际 Logo；避免按仓库名生成伪随机色，确保视觉与来源品牌一致。
                logoTint = image.awesomeAverageColor.map(Color.init(nsColor:))
            }
        }
    }

    private var repositoryDescription: some View {
        // 来源卡片只展示 GitHub Repo API 的原始描述，内容管理简介不参与展示。
        Text(verbatim: normalizedDescription(source.repoDescription) ?? "—")
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
    }

    private var repositoryMetrics: some View {
        HStack(spacing: 4) {
            metric(systemImage: "star", value: source.sourceStars, help: "GitHub Stars")
            metric(systemImage: "arrow.triangle.branch", value: source.sourceForks, help: "GitHub Forks")
            metric(systemImage: "eye", value: source.sourceSubscribers, help: "GitHub Watchers")
            metric(systemImage: "exclamationmark.circle", value: source.sourceOpenIssues, help: "GitHub Issues")
            metric(systemImage: "square.stack.3d.up", value: source.githubRepoCount, help: "Parsed projects")
        }
    }

    private func metric(systemImage: String, value: Int, help: String) -> some View {
        Label(value.formatted(.number.notation(.compactName)), systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .help(help)
            .accessibilityLabel(Text(verbatim: help))
            .accessibilityValue(Text(value, format: .number))
    }

    @ViewBuilder
    private var languageBar: some View {
        let segments = languageSegments
        if !segments.isEmpty {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(LanguageColor.color(for: segment.language))
                            .frame(width: max(2, proxy.size.width * segment.ratio))
                            .help("\(segment.language) · \(segment.ratio, format: .percent.precision(.fractionLength(1)))")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            .accessibilityLabel(Text(verbatim: source.sourceLanguage ?? "Languages"))
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if source.kind == .custom, let parseState {
                sourceParseStatus(parseState)
            } else {
                if let language = source.sourceLanguage {
                    capsule(systemImage: "circle.fill", text: language)
                }
                syncCapsule
            }
            Spacer(minLength: onDelete == nil ? 70 : 104)
        }
    }

    /// 自定义来源先显示卡片，再在固定 footer 内更新后台解析状态，避免网格因进度变化跳动。
    @ViewBuilder
    private func sourceParseStatus(_ state: AwesomeCustomSourceParseState) -> some View {
        switch state.phase {
        case .queued:
            parseStatusLabel("awesome.sources.custom.parse.queued")
        case .readingReadme:
            parseStatusLabel("awesome.sources.custom.parse.readingReadme")
        case .enrichingRepositories:
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    String(
                        format: String.l10n("awesome.sources.custom.parse.progressFormat"),
                        state.processedCount,
                        state.totalCount ?? 0
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let progress = state.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 130)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        case .completed:
            syncCapsule
        case .failed:
            Label("awesome.sources.custom.parse.failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(state.errorMessage ?? "")
        }
    }

    private func parseStatusLabel(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var languageSegments: [(language: String, ratio: Double)] {
        let valid = source.languageBytes.filter { !$0.key.isEmpty && $0.value > 0 }
        let total = valid.values.reduce(0, +)
        guard total > 0 else { return [] }
        return valid
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map { ($0.key, Double($0.value) / Double(total)) }
    }

    private func normalizedDescription(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    @ViewBuilder
    private var syncCapsule: some View {
        if !source.isAvailable || hasRefreshError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1), in: Capsule())
                .help(Text(LocalizedStringKey(
                    source.isAvailable ? "awesome.sources.stale" : "awesome.sources.unavailable"
                )))
                .accessibilityLabel(Text(LocalizedStringKey(
                    source.isAvailable ? "awesome.sources.stale" : "awesome.sources.unavailable"
                )))
        } else if let lastSyncedAt = source.lastSyncedAt {
            Label {
                Text(lastSyncedAt, style: .relative)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "clock")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: Capsule())
        }
    }

    private func capsule(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private var cardBackground: some View {
        let tint = logoTint ?? .purple
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.background)
            .overlay {
                LinearGradient(
                    colors: [
                        tint.opacity(isHovering ? 0.18 : 0.13),
                        tint.opacity(isSelected ? 0.09 : 0.035),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isSelected ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.34 : 0.2),
                lineWidth: isSelected ? 2 : 1
            )
    }
}

private extension NSImage {
    /// 采样 Logo 中有辨识度的像素，过滤透明、近黑和近白背景，避免卡片被底色冲淡。
    var awesomeAverageColor: NSColor? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0
        else { return nil }

        let horizontalStep = max(1, bitmap.pixelsWide / 12)
        let verticalStep = max(1, bitmap.pixelsHigh / 12)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weightTotal = 0.0

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: verticalStep) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: horizontalStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.2
                else { continue }

                let maximum = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minimum = min(color.redComponent, color.greenComponent, color.blueComponent)
                let brightness = (maximum + minimum) / 2
                guard brightness > 0.06, brightness < 0.94 else { continue }

                let saturation = maximum - minimum
                let weight = 0.35 + saturation
                red += color.redComponent * weight
                green += color.greenComponent * weight
                blue += color.blueComponent * weight
                weightTotal += weight
            }
        }

        guard weightTotal > 0 else { return nil }
        return NSColor(
            red: red / weightTotal,
            green: green / weightTotal,
            blue: blue / weightTotal,
            alpha: 1
        )
    }
}
