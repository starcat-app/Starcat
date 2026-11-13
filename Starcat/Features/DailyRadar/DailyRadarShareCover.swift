//
//  DailyRadarShareCover.swift
//  Starcat
//
//  复用阅读页的确定性 Canvas 离屏生成分享头图，不截取窗口或上传外部 hero_url。
//

import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// 固定尺寸、色彩环境和渲染比例，使同一 revision 在不同窗口与 Retina 屏幕上保持一致。
@MainActor
enum DailyRadarShareCover {
    static let width = 1600
    static let height = 840

    /// PNG 不写入设备、账号或日期 metadata；公开文字由 HTML 保持可选择和可访问。
    static func render(report: DailyRadarReport) throws -> (image: CGImage, png: Data) {
        let size = CGSize(width: width, height: height)
        let renderer = ImageRenderer(content:
            DailyRadarCoverView(cover: report.cover, category: report.category, seed: report.id)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, 1)
        )
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              image.width == width, image.height == height
        else { throw DailyRadarShareError.coverFailed }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
        else { throw DailyRadarShareError.coverFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DailyRadarShareError.coverFailed }
        let png = encoded as Data
        guard png.count <= 3_145_728 else { throw DailyRadarShareError.tooLarge }
        return (image, png)
    }
}
