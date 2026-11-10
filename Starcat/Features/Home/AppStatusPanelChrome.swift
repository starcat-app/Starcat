//
//  AppStatusPanelChrome.swift
//  Starcat
//
//  Toolbar 状态 popover 的卡片表面。只负责色块 / 圆角 / chevron，不读业务数据。
//
//  为什么单独抽文件：AppStatusPanel 已经承担同步、GitHub、后台任务等状态推导；
//  再把原型里的三列卡、整行卡叠进去会让「数据」和「皮」缠在一起，后续改间距只能翻 900 行。
//

import SwiftUI

/// 状态面板固定宽度。三列卡在 340 会挤标题，412 能放下「后台任务」中英文。
enum AppStatusPanelMetrics {
    static let width: CGFloat = 412
    static let cardCorner: CGFloat = 10
    static let gridSpacing: CGFloat = 8
}

/// 状态浮层的中性卡片底色，避免深色下实心黑卡与透明概览卡割裂。
enum AppStatusPanelSurface {
    /// 深色用较厚的原生材质遮住背景细节；低透明色层只能提亮，无法增强磨砂。
    static func card(
        colorScheme: ColorScheme,
        lightColor: Color = Color(nsColor: .textBackgroundColor)
    ) -> AnyShapeStyle {
        colorScheme == .dark ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(lightColor)
    }
}

/// 浅 tint 对角渐变底 + 同色描边，和洞察摘要卡同一套，避免 popover 另起一种营销渐变。
struct AppStatusTintedSurface: ViewModifier {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(
                    colors: [
                        tint.opacity(0.16),
                        tint.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous)
            )
            .background(
                // 概览卡也使用同一层磨砂，再叠加原有状态色，避免大小卡片通透程度不一致。
                AppStatusPanelSurface.card(colorScheme: colorScheme, lightColor: .clear),
                in: RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous)
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            }
    }
}

extension View {
    func appStatusTintedSurface(_ tint: Color) -> some View {
        modifier(AppStatusTintedSurface(tint: tint))
    }
}

/// 顶行三列 / 底行三列的概览卡：图标+标题、主值、说明、可选 chevron。
///
/// `accessory` 有独立按钮时不要再把整卡包成 Button，避免 SwiftUI 嵌套 Button 抢点击。
struct AppStatusOverviewCard<Icon: View, Accessory: View>: View {
    let title: LocalizedStringKey
    let value: String
    let caption: String
    let tint: Color
    var showsChevron: Bool = false
    var action: (() -> Void)?
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(
        title: LocalizedStringKey,
        value: String,
        caption: String,
        tint: Color,
        showsChevron: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.value = value
        self.caption = caption
        self.tint = tint
        self.showsChevron = showsChevron
        self.action = action
        self.icon = icon
        self.accessory = accessory
    }

    var body: some View {
        // 图标一列、文案一列、操作一列。取消按钮不能放进标题 HStack：
        // ProgressView 默认约 20pt，会把文字列撑宽，主值就会滑到图标底下。
        let content = HStack(alignment: .top, spacing: 6) {
            icon()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: value)
                    // 六张卡共用 bodyEmphasis；文案过长截断，禁止压字号，否则短卡和长卡会看起来像两套字体。
                    .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !caption.isEmpty {
                    Text(verbatim: caption)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron || Accessory.self != EmptyView.self {
                HStack(alignment: .center, spacing: 4) {
                    accessory()
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appStatusTintedSurface(tint)
        .contentShape(RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous))

        // 取消按钮这类 accessory 必须是真正的 Button；整卡再用 Button 包一层会抢点击。
        if let action {
            content
                .onTapGesture(perform: action)
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

extension AppStatusOverviewCard where Accessory == EmptyView {
    init(
        title: LocalizedStringKey,
        value: String,
        caption: String,
        tint: Color,
        showsChevron: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.init(
            title: title,
            value: value,
            caption: caption,
            tint: tint,
            showsChevron: showsChevron,
            action: action,
            icon: icon,
            accessory: { EmptyView() }
        )
    }
}

/// 诊断 / Undo Star 这种整宽行：左图标，右操作，整行可点。
struct AppStatusActionRow<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: String
    let systemImage: String
    let tint: Color
    var showsChevron: Bool = true
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(interfaceScale.font(.iconMedium, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(verbatim: subtitle)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppStatusPanelSurface.card(colorScheme: colorScheme),
            in: RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous))

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .focusEffectDisabled()
        } else {
            content
        }
    }
}

/// 本地 AI / 今日用量这类分组卡，与整宽操作行共用主题底色。
struct AppStatusGroupCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppStatusPanelSurface.card(colorScheme: colorScheme),
                in: RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStatusPanelMetrics.cardCorner, style: .continuous)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }
    }
}

/// 顶栏齿轮 / 更多：方形浅底，避免 bordered 胶囊把图标挤扁。
struct AppStatusHeaderIconButton<Label: View>: View {
    let helpKey: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .frame(width: 28, height: 28)
            .background(
                Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .help(helpKey)
    }
}
