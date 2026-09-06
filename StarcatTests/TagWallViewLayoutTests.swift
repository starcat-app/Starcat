//
//  TagWallViewLayoutTests.swift
//  StarcatTests
//
//  用真实 SwiftUI 布局验证标签数字、加载占位和选中态不会改变胶囊尺寸或标签墙换行。
//  不依赖屏幕截图像素，避免明暗主题、抗锯齿和颜色动画让布局回归测试产生噪声。
//

import SwiftUI
import Testing
@testable import Starcat

/// 直接渲染生产组件，覆盖数字位数变化及等待计数的中间态。
@MainActor
@Suite("Tag wall layout stability")
struct TagWallViewLayoutTests {
    /// ImageRenderer 使用 SwiftUI 实际测量结果，不启动主窗口或操作用户的筛选偏好。
    private func size<Content: View>(of content: Content) throws -> CGSize {
        let renderer = ImageRenderer(content: content)
        return try #require(renderer.nsImage).size
    }

    @Test("数字、零、加载占位与选中态保持同一胶囊尺寸", arguments: [128, 12_345])
    func chipKeepsReservedCountWidth(upperBound: Int) throws {
        let tag = Tag.fixture(id: "layout", name: "macOS")
        let baseline = try size(of: TagWallChip(
            tag: tag, count: upperBound, countUpperBound: upperBound,
            isSelected: false, onTap: {}
        ))
        let counts: [Int?] = [nil, 0, 1, 9, 10, 99, upperBound]
        for count in counts {
            for selected in [false, true] {
                let measured = try size(of: TagWallChip(
                    tag: tag, count: count, countUpperBound: upperBound,
                    isSelected: selected, onTap: {}
                ))
                #expect(measured == baseline)
            }
        }
    }

    @Test("标签墙在加载和选中时保持换行高度", arguments: [180.0, 220.0, 280.0])
    func wallKeepsItsRows(width: Double) throws {
        let tags = [Tag.fixture(id: "mac", name: "macOS"), Tag.fixture(id: "tool", name: "开发工具"),
                    Tag.fixture(id: "swift", name: "Swift")]
        let bounds = ["mac": 128, "tool": 12_345, "swift": 36]
        let baseline = try size(of: TagWallView(
            tags: tags, tagCounts: bounds, countUpperBounds: bounds,
            selectedTagIds: [], onTagTap: { _ in }
        ).frame(width: width).fixedSize(horizontal: false, vertical: true))
        let countSnapshots: [[String: Int]?] = [nil, [:], ["mac": 1, "tool": 99, "swift": 0]]
        for counts in countSnapshots {
            let measured = try size(of: TagWallView(
                tags: tags, tagCounts: counts, countUpperBounds: bounds,
                selectedTagIds: ["tool"], onTagTap: { _ in }
            ).frame(width: width).fixedSize(horizontal: false, vertical: true))
            #expect(measured == baseline)
        }
    }
}
