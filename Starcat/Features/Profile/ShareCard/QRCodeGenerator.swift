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
///
/// **2026-06-06 性能修复（dong4j 反馈分享卡切主题卡顿）**：
/// 加了进程级 NSCache。原版每次 `ShareCardContent` body 重渲染都会同步跑一次
/// CIFilter + CIContext.createCGImage，在主题切换的 0.18s 动画期间会被调用
/// 多次（SwiftUI 在 palette 之间插值时每帧都可能 reflow）；CIFilter 单次不算
/// 特别慢，但叠加 idCard 布局 360×280 KFImage 重建 + Metal 背景 60fps 渲染后，
/// 主线程一抖就丢帧，体验上就是「点了主题不切」。
///
/// 缓存键：`{text}|{size}`（同一 GitHub URL + 同一 sizePoints → 永远是同一张
/// QR NSImage），NSCache 容量 16 张足够覆盖分享卡所有主题 + 不同 sizePoints
/// 调用方。NSImage 本身约 64×64×4 = 16KB，16 张约 256KB，内存代价可忽略。
/// NSCache 自带线程安全 + 内存压力下自动清理，不必手动管理生命周期。
@MainActor
enum QRCodeGenerator {

    /// 进程级 QR 图缓存。
    /// countLimit = 16 是经验值：分享卡 5 主题各 1 张 + 导出图 @3x 1 张 + 余量。
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 16
        return c
    }()

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

        // 缓存命中直接返回。同一 text+size 永远是同一张 QR，无需重算。
        let cacheKey = "\(text)|\(sizePoints)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

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
        cache.setObject(nsImage, forKey: cacheKey)
        return nsImage
    }
}
