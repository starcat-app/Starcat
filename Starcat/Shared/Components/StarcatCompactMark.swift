import AppKit
import SwiftUI

/// 小按钮 / 工具条里的 Starcat 标识。
///
/// `NSApp.applicationIconImage` 自带玻璃外框 + 星空底；原尺寸塞进 14~16pt 时，
/// 黑猫与金星几乎被边框吃掉，看起来像「被压扁」。这里放大并裁掉外围，让主体占满可见区域。
struct StarcatCompactMark: View {
    var size: CGFloat = 16
    /// 相对可见框的放大倍数；约 1.6 能裁掉玻璃外框，过大则切到猫耳。
    var contentZoom: CGFloat = 1.6

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .scaleEffect(contentZoom)
            .frame(width: size, height: size)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// logo-only 动作钮的正方形浅底。
///
/// `.buttonStyle(.bordered)` 在 small 尺寸下会变成横向胶囊，图标两侧空一块；
/// 这里改成等边方底，与 GitHub mark 并排时更整齐。
struct SquareLogoActionChrome: ViewModifier {
    var side: CGFloat = 28
    /// 默认保持中性浅底；品牌入口可传入更醒目的语义背景色。
    var backgroundColor: Color = Color.secondary.opacity(0.10)

    func body(content: Content) -> some View {
        content
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

extension View {
    /// 给 logo-only 按钮套正方形浅底，替代 `.bordered` 胶囊底。
    func squareLogoActionChrome(
        side: CGFloat = 28,
        backgroundColor: Color = Color.secondary.opacity(0.10)
    ) -> some View {
        modifier(SquareLogoActionChrome(side: side, backgroundColor: backgroundColor))
    }
}
