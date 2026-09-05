//
//  AIProviderIcon.swift
//  Starcat
//
//  AI 服务商 logo 渲染组件。
//
//  模块职责：
//  - 把 `AIServiceProvider.iconAssetName` 映射成实际的 SwiftUI `Image`；
//  - 资源缺失时 fallback 到 Provider 指定的中性 SF Symbol，颜色用 `.secondary`，
//    保证 UI 不会因为某个 imageset 名字写错而留下空白；
//  - 提供单一尺寸 + 圆角裁切默认值，避免每个调用点重复 `.resizable().frame(...)`
//    样板代码。
//
//  关键约束：
//  - 品牌图标优先位于 `Resources/Assets.xcassets/AIProviders/<stem>.imageset`；上游未
//    提供可再分发矢量资源时，Provider 必须声明中性 SF Symbol fallback。
//  - macOS 15+ 的 `UIImage(named:)` / `NSImage(named:)` 在测试 host 下行为可能不稳定，
//    所以这里直接用 `Bundle.main.image(forResource:)` 探测资源是否存在再决定要不要走
//    SF Symbol fallback；这种探测在主进程 + Asset Catalog 编译后零成本。
//
//  参考样板：`Starcat/Shared/Components/LanguageIcon.swift`（同一套 "logo 优先 +
//  fallback" 模式，已经在 Sidebar 语言图标处稳定使用）。
//

import SwiftUI
import AppKit

/// 单点渲染 AI 服务商 logo 的视图。
///
/// 用法（Picker 行内、详情面板等）：
/// ```swift
/// AIProviderIconView(provider: profile.provider)              // 默认 18pt
/// AIProviderIconView(provider: .deepSeek, size: 14)           // Picker 行内常用 14
/// ```
struct AIProviderIconView: View {

    let provider: AIServiceProvider
    let size: CGFloat

    /// HOM-AIPROVIDERS-2026-06-06：
    /// 默认 18pt 对应 SwiftUI Form Picker 行内 trailing icon 的视觉密度（与 SF Symbol
    /// `body` 字号下 sparkles 的 bounding box 接近）。
    init(provider: AIServiceProvider, size: CGFloat = 18) {
        self.provider = provider
        self.size = size
    }

    var body: some View {
        Group {
            if let nsImage = sizedNSImage() {
                if provider.iconIsMonochromeWhite {
                    // HOM-AIPROVIDERS-2026-06-06 light-mode 适配（dong4j 截图反馈）：
                    // ChatGPT / Ollama / LM Studio / Grok / Moonshot 的 zeka `*_32.svg`
                    // 都是 `fill="#ffffff"` 纯白单色，light mode 下完全不可见。
                    // SwiftUI 端走 template + `.foregroundStyle(.primary)` 自动跟随
                    // colorScheme；NSImage 端 `isTemplate = true` 让 AppKit Picker cell
                    // 在 selection caption 处也走 control tint 染色，两条路径都正确。
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .foregroundStyle(.primary)
                } else {
                    // 彩色 / 渐变 logo 保留品牌原色。
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.18), style: .continuous))
                }
            } else {
                // Fallback：品牌资源异常或缺失时 UI 不留空白；SF Symbol 与字体节奏一致。
                Image(systemName: provider.fallbackSystemImageName)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .imageScale(.medium)        // 阻断父 Label / Picker 的 `.imageScale(.large)` 撑大
        .fixedSize()                // SwiftUI 端不被 line-height 撑（dropdown 的渲染路径）
        .accessibilityHidden(true)
    }

    // MARK: - NSImage 尺寸固化（caption 不走 SwiftUI 时的兜底）

    /// 从 Asset Catalog 取 NSImage，显式设置 `.size` 后返回一个**独立副本**。
    ///
    /// 为什么必须显式设 size（dong4j 2026-06-06 第三次截图反馈）：
    /// - macOS 上 SwiftUI `Picker(.menu)` 的**选中态 caption** 不走 SwiftUI 渲染
    ///   管线，而是桥接到 AppKit 的 `NSPopUpButton` cell。
    /// - NSPopUpButton cell 从 SwiftUI Label 提取出 NSImage 后，**按 `NSImage.size`
    ///   渲染，完全忽略 SwiftUI 的 `.frame()` / `.fixedSize()`**。
    /// - Asset Catalog 加载出来的 NSImage 默认 size 由 SVG 的 viewBox 决定（这里
    ///   是 32×32），所以 caption 处永远渲染成 ~22pt，无论 SwiftUI 怎么写都无效。
    /// - 解法：对 NSImage 自身设 `.size = size×size`，NSPopUpButton cell 直接按这个
    ///   size 绘制，与下拉菜单 item（NSMenu 强制 16×16）视觉一致。
    ///
    /// 为什么必须 `.copy()`：
    /// - `NSImage(named:)` 走 NSImageRep 全局缓存，**多次调用返回同一个引用**。
    /// - 直接改 `.size` 会污染缓存，影响所有用同一 asset 的位置（比如详情页 30pt
    ///   logo 会被 Picker 14pt 调用方意外缩小）。
    /// - `.copy()` 创建独立 NSImage 实例，`.size` 独立，representations 浅引用共享
    ///   （SVG 矢量数据共用是安全的）。
    ///
    /// 退路：`as? NSImage` cast 失败时直接 return base，**不修改 base.size 避免污染**。
    /// 防御式写法；NSImage.copy() 一定返回 NSImage，实际不会进入 fallback。
    private func sizedNSImage() -> NSImage? {
        guard let base = NSImage(named: provider.iconAssetName) else { return nil }
        guard let copy = base.copy() as? NSImage else { return base }
        copy.size = NSSize(width: size, height: size)
        if provider.iconIsMonochromeWhite {
            // 让 AppKit Picker cell 走 template 染色，与 SwiftUI `.foregroundStyle` 配合
            copy.isTemplate = true
        }
        return copy
    }
}

#Preview("Provider 图标长廊（24 个）") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            ForEach(AIServiceProvider.allCases) { provider in
                VStack(spacing: 6) {
                    AIProviderIconView(provider: provider, size: 32)
                    Text(provider.iconAssetName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.thinMaterial)
                )
            }
        }
        .padding()
    }
    .frame(width: 640, height: 480)
}
