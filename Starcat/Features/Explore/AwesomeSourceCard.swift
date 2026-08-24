//
//  AwesomeSourceCard.swift
//  Starcat
//
//  来源选择 Sheet 的固定三列 Repo 风格卡片。
//

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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 13) {
                    header
                    summaryText
                    Spacer(minLength: 0)
                    metadata
                }
                .padding(15)
                .frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
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

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("awesome.sources.removeCustom"))
                .accessibilityLabel(Text("awesome.sources.removeCustom"))
                .padding(9)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            AwesomeSourceLogo(source: source, size: 52)
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
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
        }
        .padding(.trailing, onDelete == nil ? 0 : 26)
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
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected
                ? Color.accentColor.opacity(0.09)
                : Color.primary.opacity(isHovering ? 0.05 : 0.025))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isSelected ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.34 : 0.2),
                lineWidth: isSelected ? 2 : 1
            )
    }
}
