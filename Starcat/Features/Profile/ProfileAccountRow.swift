//
//  ProfileAccountRow.swift
//  Starcat
//
//  组织与 Sponsors 共用的账户行；整行可点击，并保持稳定的斑马纹和悬停反馈。
//

import AppKit
import Kingfisher
import SwiftUI

/// 原生 Button 保留键盘与辅助功能语义；鼠标悬停仅改变背景，不移动文字或头像。
struct ProfileAccountRow: View {
    let login: String
    let avatarUrl: String?
    var detail: String? = nil
    let rowIndex: Int

    @Environment(\.displayScale) private var displayScale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(GitHubURLs.userProfile(login: login))
        } label: {
            HStack(spacing: 10) {
                KFImage(GitHubAvatarURL.imageURL(
                    from: avatarUrl, displayDiameter: 32,
                    displayScale: displayScale, minimumPixelSize: 64
                ))
                .resizable()
                .cancelOnDisappear(true)
                .placeholder {
                    Image(systemName: "person.crop.circle")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
                Text(verbatim: login)
                    .font(.system(size: interfaceScale.scaled(13), weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.accentColor.opacity(0.08)
                    : (rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .help(detail.map { "\(login)\n\($0)" } ?? login)
        .accessibilityLabel(Text(verbatim: login))
    }
}
