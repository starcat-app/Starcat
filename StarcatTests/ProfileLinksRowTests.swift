//
//  ProfileLinksRowTests.swift
//  StarcatTests
//
//  离屏验证社交行的稳定高度、居中位置与组织头像的最右侧对齐，不操作应用窗口。
//

import AppKit
import SwiftUI
import Testing
@testable import Starcat

/// 使用真实 SwiftUI 行渲染；组织头像 URL 为 nil，验证期间不会请求远程图片。
@MainActor
@Suite("Profile social and organization row")
struct ProfileLinksRowTests {
    /// 用户资料组合覆盖零至四个社交入口，以及不同数量的组织。
    private func user(linkCount: Int, organizationCount: Int) -> GitHubUserDTO {
        GitHubUserDTO(
            id: 42, login: "alice", name: nil, avatarUrl: nil,
            company: linkCount >= 1 ? "Example" : nil,
            email: linkCount >= 4 ? "alice@example.com" : nil,
            blog: linkCount >= 2 ? "https://example.com" : nil,
            twitterUsername: linkCount >= 3 ? "alice" : nil,
            organizations: (0..<organizationCount).map { index in
                GitHubOrganizationDTO(id: Int64(index), login: "org-\(index)", avatarUrl: nil, description: nil)
            }
        )
    }

    /// 固定一倍像素比例和颜色环境，让对齐断言不依赖屏幕、主题或运行中的 App。
    private func render(_ user: GitHubUserDTO, width: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: ProfileLinksRow(user: user)
            .environment(\.colorScheme, .dark)
            .background(.black))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.cgImage)
    }

    @Test("窄侧栏和所有社交入口组合保持单行高度", arguments: [212.0, 252.0, 292.0], [0, 1, 2, 3, 4])
    func rowStaysCompact(width: Double, linkCount: Int) throws {
        for count in [1, 3, 10, 101] {
            let image = try render(user(linkCount: linkCount, organizationCount: count), width: width)
            #expect(image.width == Int(width))
            #expect(image.height == 20)
        }
    }

    /// 12pt 头像在 20pt 点击区域内居中，贴右时保留 4pt 留白，不要求绘制像素贴边。
    @Test("组织贴右展示且社交图标位置不变", arguments: [212.0, 252.0, 292.0])
    func organizationsStayAtTrailingEdge(width: Double) throws {
        let baseline = NSBitmapImageRep(cgImage: try render(user(linkCount: 2, organizationCount: 0), width: width))
        let result = NSBitmapImageRep(cgImage: try render(user(linkCount: 2, organizationCount: 3), width: width))
        var changedColumns: [Int] = []
        for column in 0..<result.pixelsWide {
            let changed = (0..<result.pixelsHigh).contains { row in
                baseline.colorAt(x: column, y: row) != result.colorAt(x: column, y: row)
            }
            if changed { changedColumns.append(column) }
        }
        let firstChangedColumn = try #require(changedColumns.first)
        let lastChangedColumn = try #require(changedColumns.last)
        #expect(firstChangedColumn >= Int(width / 2) + 25 + 8)
        let trailingInset = result.pixelsWide - 1 - lastChangedColumn
        // 允许一像素光栅化误差，同时约束组织仍贴右且图标未贴到点击区域边缘。
        #expect((3...5).contains(trailingInset))
    }
}
