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
    let summary: String?
    let isSelected: Bool
    let hasRefreshError: Bool
    let onToggle: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovering = false
    @State private var logoTint: Color?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    summaryText
                    Spacer(minLength: 0)
                    Divider()
                    metadata
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 198, alignment: .topLeading)
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
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            AwesomeSourceLogo(source: source, size: 54) { image in
                // 卡片色彩来自实际 Logo；避免按仓库名生成伪随机色，确保视觉与来源品牌一致。
                logoTint = image.awesomeAverageColor.map(Color.init(nsColor:))
            }
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
            Spacer(minLength: 4)
        }
        .padding(.trailing, onDelete == nil ? 62 : 96)
    }

    private var summaryText: some View {
        Text(summary ?? source.repoFullName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            capsule(
                systemImage: "star.fill",
                text: source.sourceStars.formatted(.number.notation(.compactName))
            )
            capsule(
                systemImage: "square.stack.3d.up.fill",
                text: source.githubRepoCount.formatted(.number.notation(.compactName))
            )
            Spacer(minLength: 0)
            syncCapsule
        }
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
