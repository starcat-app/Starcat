//
//  RepoWorkspaceHeader.swift
//  Starcat
//
//  三类仓库工作区共用的身份顶栏与搜索输入；操作由调用者保留，身份只取已有仓库快照。
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
                .font(interfaceScale.font(.body, weight: .medium))
                .controlSize(.regular)
                .layoutPriority(1)
        }
        .padding(.horizontal, 18)
        .frame(height: max(64, interfaceScale.scaled(64)))
    }
}

/// 左栏搜索统一外观与窗口内快捷键；查询与防抖仍由各页面原有逻辑负责。
struct RepoWorkspaceSearchField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    /// Issues 已有清空入口；其他页面只复用外观，不额外增加操作。
    var showsClearButton = false

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if showsClearButton && !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("common.clear")
                .accessibilityLabel(Text("common.clear"))
            }
            Text(verbatim: "⌘F")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .font(interfaceScale.font(.body))
        .padding(.horizontal, 8)
        .frame(height: interfaceScale.scaled(28))
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(placeholder)
        .background {
            // 由当前窗口的 SwiftUI 快捷键路由聚焦输入框，不改动全局菜单与正文阅读状态。
            Button(placeholder) { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// 保留退出命令回调，并像 Skills 底栏一样注册取消快捷键，提供不依赖输入焦点的 Esc 入口。
    /// 两条入口复用页面自己的动作，草稿保存、退出放大和任务清理仍由原工作区负责。
    func workspaceEscapeAction(_ action: @escaping () -> Void) -> some View {
        onExitCommand(perform: action)
            .background {
                Button("common.close", action: action)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .accessibilityHidden(true)
            }
    }
}
