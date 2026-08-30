//
//  ViewSnapshotPasteboardTests.swift
//  StarcatTests
//
//  只验证固定色块能出图、过小尺寸被拒绝。不拿 Swift Charts 做像素金图。
//  剪贴板写入单独 serialized，避免并行测试互相清 NSPasteboard.general。
//

import AppKit
import SwiftUI
import Testing
@testable import Starcat

@Suite("View snapshot pasteboard", .serialized)
struct ViewSnapshotPasteboardTests {

    @Test @MainActor
    func renderImageRejectsUndersizedView() {
        let image = ViewSnapshotPasteboard.renderImage(
            Color.blue,
            size: CGSize(width: 8, height: 8)
        )
        #expect(image == nil)
    }

    @Test @MainActor
    func renderImageDoesNotPumpMainRunLoop() {
        // 回归：全局 flush / RunLoop.run 会重入侧栏 TimelineView 并 SIGSEGV。
        // 这个测试只要能同步返回就证明截图不再转主 runloop。
        let image = ViewSnapshotPasteboard.renderImage(
            Color.green.frame(width: 120, height: 60),
            size: CGSize(width: 120, height: 60)
        )
        #expect(image != nil)
    }

    @Test @MainActor
    func renderImageProducesNonEmptyBitmap() {
        let image = ViewSnapshotPasteboard.renderImage(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue)
                .frame(width: 180, height: 90),
            size: CGSize(width: 180, height: 90)
        )
        let bitmap = image.flatMap(\.tiffRepresentation).flatMap(NSBitmapImageRep.init(data:))
        #expect(image != nil)
        #expect((bitmap?.pixelsWide ?? 0) > 1)
        #expect((bitmap?.pixelsHigh ?? 0) > 1)
    }

    @Test @MainActor
    func copyImageWritesPNGAndTIFF() {
        let pasteboard = NSPasteboard.general
        // NSPasteboardItem 一旦写入某个 pasteboard 就不能再次写入。测试必须复制其数据，
        // 否则 macOS 26.6 在 defer 恢复现场时会抛 NSInvalidArgumentException。
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !previous.isEmpty {
                pasteboard.writeObjects(previous)
            }
        }

        let wrote = ViewSnapshotPasteboard.copyImage(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange)
                .frame(width: 160, height: 80),
            size: CGSize(width: 160, height: 80)
        )
        #expect(wrote)
        #expect(pasteboard.data(forType: .png) != nil)
        #expect(pasteboard.data(forType: .tiff) != nil)
    }
}
