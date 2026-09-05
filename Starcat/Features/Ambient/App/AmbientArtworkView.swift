//
//  AmbientArtworkView.swift
//  Starcat
//
//  全屏方形 artwork。它按 tile 实际点数和屏幕 backing scale 请求 GitHub 头像，
//  使用 Kingfisher 下采样并关闭内部 fade，让槽位 3D flip 成为唯一明显动画。
//

import Kingfisher
import SwiftUI

/// Ambient 大图 URL 与稳定占位的纯函数集合。
enum AmbientArtworkStyle {
    static let paletteCount = 8

    static func imageURL(
        from urlString: String?,
        tilePointSize: Double,
        displayScale: Double
    ) -> URL? {
        GitHubAvatarURL.imageURL(
            from: urlString,
            displayDiameter: tilePointSize,
            displayScale: displayScale,
            minimumPixelSize: 64,
            maximumPixelSize: 1_024
        )
    }

    static func targetPixelSize(tilePointSize: Double, displayScale: Double) -> Int {
        let requested = Int(ceil(max(1, tilePointSize) * max(1, displayScale)))
        return min(max(requested, 64), 1_024)
    }

    static func monogram(from title: String) -> String? {
        guard let character = title.first(where: { !$0.isWhitespace }) else { return nil }
        return String(character).uppercased()
    }

    /// Swift 的 `hashValue` 每进程随机；FNV-1a 保证同一 card id 永远映射同一占位色。
    static func paletteIndex(for cardID: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in cardID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(paletteCount))
    }
}

/// 为 Ambient tile 解码目标尺寸图片，并在 URL 无效或网络失败时保留稳定占位。
struct AmbientArtworkView: View {
    @Environment(\.displayScale) private var displayScale

    let card: AmbientCardModel
    let tilePointSize: Double

    var body: some View {
        ZStack {
            AmbientArtworkPlaceholder(card: card)

            if let url = AmbientArtworkStyle.imageURL(
                from: card.artworkURLString,
                tilePointSize: tilePointSize,
                displayScale: displayScale
            ) {
                let pixelSize = AmbientArtworkStyle.targetPixelSize(
                    tilePointSize: tilePointSize,
                    displayScale: displayScale
                )
                let processor = DownsamplingImageProcessor(
                    size: CGSize(width: pixelSize, height: pixelSize)
                )

                KFImage(source: .network(KF.ImageResource(
                    downloadURL: url,
                    cacheKey: url.absoluteString
                )))
                .setProcessor(processor)
                .cacheOriginalImage()
                .cancelOnDisappear(true)
                .resizable()
                .scaledToFill()
            }
        }
        .frame(width: tilePointSize, height: tilePointSize)
        // Apple Music 屏保式 full-bleed 网格要求直角无缝拼接；图片可在方格内部裁切。
        .clipped()
        .accessibilityHidden(true)
    }
}

/// 网络状态不可控时仍能稳定区分卡片的纯本地占位。
private struct AmbientArtworkPlaceholder: View {
    let card: AmbientCardModel

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.29, blue: 0.35),
        Color(red: 0.30, green: 0.23, blue: 0.36),
        Color(red: 0.20, green: 0.34, blue: 0.31),
        Color(red: 0.37, green: 0.25, blue: 0.23),
        Color(red: 0.25, green: 0.29, blue: 0.43),
        Color(red: 0.35, green: 0.31, blue: 0.20),
        Color(red: 0.25, green: 0.35, blue: 0.40),
        Color(red: 0.39, green: 0.24, blue: 0.31)
    ]

    var body: some View {
        ZStack {
            Self.palette[AmbientArtworkStyle.paletteIndex(for: card.id)]

            if let monogram = AmbientArtworkStyle.monogram(from: card.title) {
                Text(monogram)
                    .font(.largeTitle)
                    .bold()
                    .foregroundStyle(.primary)
            } else {
                // 故意弱化：无可提取字符时的装饰性最终占位，卡片标题仍由外层可访问文本提供。
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
