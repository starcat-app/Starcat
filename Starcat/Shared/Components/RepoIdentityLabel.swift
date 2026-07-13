//
//  RepoIdentityLabel.swift
//  Starcat
//
//  仓库身份行：owner 头像 + `owner/repo` 文案。
//
//  设计约束：
//  - 头像走 `RemoteAvatar` + `RepoAvatarURL` / 可选 `ownerAvatar`，复用 Kingfisher 缓存，
//    不在 RAG / 知识库场景另开拉取通道。
//  - 只负责「识别仓库」的紧凑展示；列表描述、统计等仍由调用方排版。
//

import SwiftUI

/// 仓库名旁的圆形 logo + fullName。
struct RepoIdentityLabel: View {
    /// 展示用 `owner/repo`；owner 段用于拼公开头像 URL。
    let fullName: String
    /// 本地已有头像 URL 时优先（如 `Repo.ownerAvatar`），否则拼 `github.com/{owner}.png`。
    var ownerAvatarURL: String? = nil
    var avatarSize: CGFloat = 16
    var font: Font = .caption.weight(.medium)
    var lineLimit: Int = 1
    var spacing: CGFloat = 6
    /// 芯片等小尺寸默认不描边，避免 14pt 圆上再加线显得脏。
    var showAvatarBorder: Bool = false

    private var ownerLogin: String {
        if let slash = fullName.firstIndex(of: "/") {
            return String(fullName[..<slash])
        }
        return fullName
    }

    private var resolvedAvatarURL: String {
        if let ownerAvatarURL, !ownerAvatarURL.isEmpty {
            return ownerAvatarURL
        }
        return RepoAvatarURL.from(owner: ownerLogin)
    }

    var body: some View {
        HStack(spacing: spacing) {
            RemoteAvatar(
                urlString: resolvedAvatarURL,
                size: avatarSize,
                showBorder: showAvatarBorder
            )
            Text(fullName)
                .font(font)
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
    }
}
