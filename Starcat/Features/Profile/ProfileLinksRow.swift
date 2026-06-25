//
//  ProfileLinksRow.swift
//  Starcat
//
//  Sidebar 头像卡的个人主页快捷链接行：bio + 一排紧凑图标（company / blog / twitter / email）。
//  HOM-PROFILE 2026-06-05 引入。
//
//  设计动机：
//  - GitHub 个人主页有 ~6 个字段（bio / company / location / email / blog / twitter），
//    全部展示成多行文字会挤爆 sidebar。
//  - 用"图标 + tooltip"的紧凑模式：① 节省垂直空间；② 一眼能看出"哪些字段已填、哪些没填"。
//  - 可点击的字段（blog / twitter / email / @company）直接跳浏览器/邮件 app；纯文字 company
//    用 tooltip 显示完整内容。location 不展示：GitHub 只返回自由文本，Starcat 没有可靠跳转目标。
//
//  布局：
//  ┌────────────────────────────────────────┐
//  │ bio 文字（如有，最多 2 行折行）             │
//  ├────────────────────────────────────────┤
//  │ 🏢 🔗 🐦 ✉️                            │
//  └────────────────────────────────────────┘
//
//  关键约束：
//  - 非空字段才显示对应图标（不强制占位）。
//  - 全部按钮统一 `.pressableHover()` 反馈，与 sidebar 其它可点击元素一致。
//  - 链接打开统一走 `NSWorkspace.shared.open(_:)`，邮箱走 `mailto:`。
//

import SwiftUI
import AppKit

struct ProfileLinksRow: View {

    let user: GitHubUserDTO

    var body: some View {
        // dong4j 2026-06-05 反馈：bio + 链接行整体居中（之前左对齐与三栏统计/草坪不齐）。
        // bio 多行时按"段落居中"（multilineTextAlignment(.center)），链接图标行用
        // HStack 不带 Spacer + frame(maxWidth:.infinity) 居中。
        VStack(spacing: 6) {
            if let bio = user.bio?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    // Sidebar 用户卡需要高度稳定；超长 bio 只展示两行，完整内容交给 tooltip。
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .help(bio)
            }

            // 图标按钮行：每个字段独立判 nil/空，最终至少展示 1 个才渲染该行。
            let buttons = makeIconButtons()
            if !buttons.isEmpty {
                HStack(spacing: 10) {
                    ForEach(buttons) { btn in
                        ProfileIconButton(item: btn)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// 根据 user 字段生成图标按钮项列表。
    /// 只把"非空"的字段构造成 ProfileLinkItem，避免渲染时出现"灰色 disabled 图标"。
    private func makeIconButtons() -> [ProfileLinkItem] {
        var items: [ProfileLinkItem] = []

        if let company = user.company?.trimmed, !company.isEmpty {
            // company 形如 "@apple" 或 "Apple Inc."。以 @ 开头的视为组织名，可跳 GitHub 主页。
            let trimmed = company.hasPrefix("@") ? String(company.dropFirst()) : company
            let url = company.hasPrefix("@") ? GitHubURLs.userProfile(login: trimmed) : nil
            items.append(.init(
                kind: .company,
                systemImage: "building.2",
                tooltip: company,
                url: url
            ))
        }

        if let blog = user.blog?.trimmed, !blog.isEmpty {
            // GitHub 不保证 blog 带 scheme，缺失时补 https://
            let url = normalizeURL(blog)
            items.append(.init(
                kind: .blog,
                systemImage: "link",
                tooltip: blog,
                url: url
            ))
        }

        if let twitter = user.twitterUsername?.trimmed, !twitter.isEmpty {
            let handle = twitter.hasPrefix("@") ? String(twitter.dropFirst()) : twitter
            let url = URL(string: "https://x.com/\(handle)")
            items.append(.init(
                kind: .twitter,
                systemImage: "bird",
                tooltip: "@\(handle)",
                url: url
            ))
        }

        if let email = user.email?.trimmed, !email.isEmpty {
            let url = URL(string: "mailto:\(email)")
            items.append(.init(
                kind: .email,
                systemImage: "envelope",
                tooltip: email,
                url: url
            ))
        }

        return items
    }

    /// 补全 scheme：用户在 GitHub 上常写 `dong4j.github.io` 这种不带 https 的字符串。
    private func normalizeURL(_ raw: String) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        return URL(string: "https://\(raw)")
    }
}

// MARK: - 单个图标按钮

/// 一个 profile 图标按钮：图标 + tooltip + 可选点击跳转。
///
/// 提取成独立 View 是为了让 `.pressableHover()` / `.help()` 的写法保持简洁，
/// 同时方便后续替换为 markdown / sheet 等更丰富的展示形式。
private struct ProfileIconButton: View {
    let item: ProfileLinkItem

    var body: some View {
        Button {
            if let url = item.url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Image(systemName: item.systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
                .foregroundStyle(item.url == nil ? .secondary : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 可点击的（带 url）用 pressableHover；纯文本字段（如普通 company）也加 hover，
        // 让用户感知到"可以 hover 出 tooltip"。scale 设为 1.0 避免无意义放大。
        .pressableHover(scale: item.url == nil ? 1.0 : 1.06)
        .help(item.tooltip)
        // 禁用不可点击项的 hit-test 不必，因为 NSWorkspace.open(nil) 已 no-op。
    }
}

// MARK: - 数据模型

/// 一行 profile 链接的描述。
///
/// 内部用 enum kind 区分类型，仅服务于稳定 id（ForEach 用）+ 后续可能的差异化样式。
private struct ProfileLinkItem: Identifiable {
    let kind: Kind
    let systemImage: String
    let tooltip: String
    let url: URL?

    var id: String { kind.rawValue }

    enum Kind: String {
        case company, blog, twitter, email
    }
}

// MARK: - String trim helper

private extension String {
    /// 去除首尾空白；解构出可读名字而非散落 `trimmingCharacters(in: .whitespacesAndNewlines)`。
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
