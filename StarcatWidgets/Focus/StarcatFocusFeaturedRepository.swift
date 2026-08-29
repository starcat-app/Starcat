//
//  StarcatFocusFeaturedRepository.swift
//  StarcatWidgets
//
//  Focus Widget 中用于突出首选仓库的只读展示视图。
//

import SwiftUI

/// 首选仓库承担 Focus Widget 的第一视觉层级，其余仓库继续使用紧凑列表。
///
/// Medium 使用紧凑布局给右侧候选留出空间；大尺寸规格移除后不再保留另一套分支。
struct StarcatFocusFeaturedRepository: View {
    let repository: WidgetRepository

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: repository.owner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: repository.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                repositoryMetadata
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository.focusAccessibilityLabel)
        .accessibilityHint(Text("widget.common.openRepository"))
    }

    @ViewBuilder
    private var repositoryMetadata: some View {
        HStack(spacing: 8) {
            if let language = repository.language {
                Label {
                    Text(verbatim: language)
                } icon: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .lineLimit(1)
            }

            Label {
                Text(repository.starsCount, format: .number.notation(.compactName))
            } icon: {
                Image(systemName: "star.fill")
            }

            StarcatFocusStatusLabel(source: repository.focusSource)
        }
    }
}
