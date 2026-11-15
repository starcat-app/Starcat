//
//  RepoWorkspaceHeader.swift
//  Starcat
//
//  三类仓库工作区共用的身份顶栏；操作由调用者保留，身份只取已有仓库快照。
//

import SwiftUI

/// 缺少简介时仍保留同一高度，使不同入口的正文起点一致。
struct RepoWorkspaceHeader<Actions: View>: View {
    let target: RepoFileBrowserTarget
    @ViewBuilder let actions: () -> Actions
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 12) {
            RemoteAvatar(urlString: target.ownerAvatar ?? RepoAvatarURL.from(owner: target.owner),
                         size: 28, showBorder: false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(verbatim: target.fullName)
                        .font(.system(size: interfaceScale.scaled(16), weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.fullName)
                    Text(target.isPrivate ? "repo.files.visibility.private" : "repo.files.visibility.public")
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(.secondary)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .fixedSize()
                }
                if let summary = target.summary, !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(summary)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            actions()
                .layoutPriority(1)
        }
        .padding(.horizontal, 18)
        .frame(height: max(64, interfaceScale.scaled(64)))
    }
}
