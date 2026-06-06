//
//  QRCodeGenerator.swift
//  Starcat
//
//  HOM-173 follow-up：分享卡片二维码生成。
//  仅服务于 ShareCard 的 ID Card 系列主题（白卡 / 黑卡），
//  把用户 GitHub 主页 URL 编码成 QR，渲染在卡片右下角。
//
//  实现选择：
//  - 用 Apple `CoreImage.CIFilter.qrCodeGenerator()` 而非引入第三方库——
//    macOS / iOS 内置，零依赖、零包体增量；GitHub URL 长度 < 50 字符，
//    "M" 级纠错（15% 容错）足够覆盖正常打印 + 屏幕扫码场景。
//  - 默认输出 NSImage（卡片 SwiftUI 视图直接消费 `Image(nsImage:)`），
//    分享卡 ImageRenderer @3x 导出时 QR 会同步放大、不会糊。
//
//  渲染细节：
//  - CIFilter 默认输出 ~21×21 的小图（Version 1，message 越长版本越高），
//    用 `CGAffineTransform(scaleX:y:)` 整数倍放大到目标 pt（通常 64-72pt）。
//    **必须用整数缩放比例**，否则像素边界会被双线性插值糊掉，扫码失败。
//  - 默认黑前景 + 透明背景；caller 想反色（白卡用黑 QR、黑卡用白 QR）
//    通过 SwiftUI 的 `.colorMultiply` 实现，generator 本身不变。
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// QR 码生成器。无状态，方法即工具。
enum QRCodeGenerator {

    /// 把字符串编码为 NSImage QR。
    ///
    /// - Parameters:
    ///   - text: 要编码的内容。GitHub URL 通常 30-60 字符，Version 2-4 QR；
    ///           过长（>2000 字符）会编码失败返回 nil。
    ///   - sizePoints: 目标 pt 尺寸（正方形）。生成器内部按"原始尺寸"算放大比例，
    ///                 再交给 SwiftUI 等比缩放。建议 ≥ 64pt 保证手机扫码识别率。
    /// - Returns: 黑色 QR + 透明背景的 NSImage；编码失败返回 nil。
    static func generate(text: String, sizePoints: CGFloat = 72) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // M = ~15% 错误恢复。L=7%、Q=25%、H=30%。
        // M 是 GitHub URL 这种短文本 + 卡片清晰展示场景的最佳平衡。
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            AppLog.ui.error("QRCodeGenerator: filter.outputImage returned nil for message length=\(text.count, privacy: .public)")
            return nil
        }

        // 计算放大比例（整数倍最稳）。outputImage.extent 一般是 ~25×25 ~ 41×41。
        // 取目标 sizePoints / extent.width，向上取整为整数倍后再放大。
        let extent = outputImage.extent
        let scale = max(1, Int(ceil(sizePoints / extent.width)))
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))

        // CIImage → CGImage（NSCIImageRep / NSImage 都行，CGImage 是最稳的中间格式）
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            AppLog.ui.error("QRCodeGenerator: failed to create CGImage from scaled CIImage")
            return nil
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: sizePoints, height: sizePoints))
        return nsImage
    }
}
