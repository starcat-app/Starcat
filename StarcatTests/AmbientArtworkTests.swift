//
//  AmbientArtworkTests.swift
//  StarcatTests
//
//  校验大 tile 像素参数、稳定占位与 nextCard 有界去重。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Ambient Artwork")
struct AmbientArtworkTests {
    @Test("GitHub avatar 按 backing scale 请求并钳制 64 到 1024")
    func sizesAvatarURLForTile() throws {
        let base = "https://github.com/apple.png?size=80"
        let small = try #require(AmbientArtworkStyle.imageURL(
            from: base,
            tilePointSize: 20,
            displayScale: 2
        ))
        let medium = try #require(AmbientArtworkStyle.imageURL(
            from: base,
            tilePointSize: 200,
            displayScale: 2
        ))
        let large = try #require(AmbientArtworkStyle.imageURL(
            from: base,
            tilePointSize: 800,
            displayScale: 2
        ))

        #expect(queryValue("size", in: small) == "64")
        #expect(queryValue("size", in: medium) == "400")
        #expect(queryValue("size", in: large) == "1024")
    }

    @Test("占位 monogram 与色板索引跨调用稳定")
    func placeholderIsStable() {
        let first = AmbientArtworkStyle.paletteIndex(for: "repo:42")
        let second = AmbientArtworkStyle.paletteIndex(for: "repo:42")

        #expect(first == second)
        #expect((0..<AmbientArtworkStyle.paletteCount).contains(first))
        #expect(AmbientArtworkStyle.monogram(from: "  apple/swift") == "A")
        #expect(AmbientArtworkStyle.monogram(from: "   ") == nil)
    }

    @Test("只预取 nextCard 且按规范化 URL 去重")
    func prefetchSelectionIsBoundedAndDeduped() {
        let current = card(id: "current", artwork: "https://github.com/current.png")
        let duplicateNext = card(id: "next-2", artwork: "https://github.com/shared.png?size=80")
        let snapshots = [
            snapshot(id: 0, current: current, next: card(id: "next-1", artwork: "https://github.com/shared.png")),
            snapshot(id: 1, current: current, next: duplicateNext),
            snapshot(id: 2, current: current, next: card(id: "invalid", artwork: ""))
        ]

        let urls = AmbientImagePrefetcher.nextArtworkURLs(
            snapshots: snapshots,
            tilePointSize: 200,
            displayScale: 2
        )

        #expect(urls.count == 1)
        #expect(urls.count <= snapshots.count)
        #expect(queryValue("size", in: urls[0]) == "400")
    }

    @Test("五行布局零间距铺满高度并横向超宽裁切")
    func gridMetricsFillAndCropAvailableGeometry() {
        let desktop = AmbientGridMetrics(size: CGSize(width: 1_920, height: 1_080))
        let narrow = AmbientGridMetrics(size: CGSize(width: 200, height: 1_000))
        let transient = AmbientGridMetrics(size: .zero)

        #expect(desktop.tilePointSize == 216)
        #expect(desktop.columnCount == 9)
        #expect(desktop.contentWidth == 1_944)
        #expect(desktop.contentWidth >= desktop.viewportWidth)
        #expect(desktop.contentHeight == desktop.viewportHeight)
        #expect(narrow.columnCount == 1)
        #expect(narrow.contentWidth == narrow.viewportWidth)
        #expect(narrow.contentHeight == narrow.viewportHeight)
        #expect(!transient.isUsable)
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func card(id: String, artwork: String) -> AmbientCardModel {
        AmbientCardModel(
            id: id,
            visualKey: id,
            title: id,
            artworkURLString: artwork,
            subtitle: nil,
            metadata: [:]
        )
    }

    private func snapshot(
        id: Int,
        current: AmbientCardModel,
        next: AmbientCardModel
    ) -> AmbientSlotSnapshot {
        AmbientSlotSnapshot(id: id, card: current, nextCard: next)
    }
}
