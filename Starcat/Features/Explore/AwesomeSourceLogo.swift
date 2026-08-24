//
//  AwesomeSourceLogo.swift
//  Starcat
//
//  Awesome 来源的共享 Logo：优先内容管理图片，其次 GitHub owner avatar，最后使用语义图标。
//

import Kingfisher
import SwiftUI

/// Sheet 与侧边栏共用同一图片回退和 Kingfisher 缓存策略，避免来源列表退化成重复的占位图标。
struct AwesomeSourceLogo: View {
    let source: AwesomeSource
    var size: CGFloat = 52

    @State private var usesOwnerFallback = false

    var body: some View {
        Group {
            if let url = activeURL {
                KFImage(url)
                    .resizable()
                    .placeholder { symbolFallback }
                    .fade(duration: 0.15)
                    .onFailure { _ in
                        if !usesOwnerFallback, source.imageURL != nil, ownerAvatarURL != nil {
                            usesOwnerFallback = true
                        }
                    }
                    .scaledToFill()
            } else {
                symbolFallback
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: max(5, size * 0.2), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: max(5, size * 0.2), style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var ownerAvatarURL: URL? {
        let owner = source.repoFullName.split(separator: "/").first.map(String.init)
        return owner.flatMap { URL(string: "https://github.com/\($0).png?size=104") }
    }

    private var activeURL: URL? {
        // 两级图片都交给 Kingfisher 的内存与磁盘缓存；失败后不重复请求内容管理图片。
        guard !usesOwnerFallback else { return ownerAvatarURL }
        return source.imageURL ?? ownerAvatarURL
    }

    private var symbolFallback: some View {
        Image(systemName: "sparkles.rectangle.stack")
            .font(.system(size: max(12, size * 0.38), weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
    }
}
