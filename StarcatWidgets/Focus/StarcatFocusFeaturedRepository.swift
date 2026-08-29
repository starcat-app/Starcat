//
//  StarcatFocusFeaturedRepository.swift
//  StarcatWidgets
//
//  Focus Widget 中用于突出首选仓库的只读展示视图。
//

import SwiftUI

/// 首选仓库承担 Focus Widget 的第一视觉层级，其余仓库继续使用紧凑列表。
///
/// Medium 使用 compact 布局给右侧候选留出空间；Large 才展示描述与标签，
/// 避免把同一份信息硬塞进所有尺寸造成截断。
struct StarcatFocusFeaturedRepository: View {
    let repository: WidgetRepository
    let isExpanded: Bool

    var body: some View {
        if isExpanded {
            HStack(spacing: 12) {
                StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(repository.owner)/\(repository.name)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let description = repository.description {
                        Text(verbatim: description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 10) {
                        repositoryMetadata
                        ForEach(repository.tags.prefix(2), id: \.self) { tag in
                            Text(verbatim: "#\(tag)")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(repository.focusAccessibilityLabel)
            .accessibilityHint(Text("widget.common.openRepository"))
        } else {
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
