//
//  ProfileAccountAvatar.swift
//  Starcat
//
//  账户浮层中组织与 Sponsors 共用的头像入口。
//

import AppKit
import Kingfisher
import SwiftUI

/// 头像代替文字行后，名称与简介仍可悬停查看，键盘焦点用边框表示。
struct ProfileAccountAvatar: View {
    let login: String
    let avatarUrl: String?
    var detail: String? = nil
    let size: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.displayScale) private var displayScale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        Button {
            NSWorkspace.shared.open(GitHubURLs.userProfile(login: login))
        } label: {
            KFImage(GitHubAvatarURL.imageURL(
                from: avatarUrl, displayDiameter: size,
                displayScale: displayScale, minimumPixelSize: 64
            ))
            .resizable()
            .cancelOnDisappear(true)
            .placeholder {
                Image(systemName: "person.crop.circle")
                    .font(interfaceScale.font(size: 18))
                    .foregroundStyle(.secondary)
            }
            .scaledToFill()
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.045))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    isHovered || isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($isFocused)
        .clickablePointer()
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .help(detail.map { "\(login)\n\($0)" } ?? login)
        .accessibilityLabel(Text(verbatim: login))
    }
}
