//
//  RAGMetadataDrillDownStyle.swift
//  Starcat
//
//  元数据面板可下钻数值/行的统一高亮样式。
//  默认 accent 浅底 + 细描边提示可点；hover 加深并切换 link 手型，与索引问题行一致。
//

import SwiftUI

/// 元数据下钻控件的视觉档位：紧凑数值、顶部统计卡、整行仓库。
enum MetadataDrillDownVariant {
    case compact
    case stat
    case row
}

/// 与知识库分片 / `@` mention 列表同一套斑马纹：奇数行极淡 primary，明暗主题均可扫描。
private func metadataZebraBackground(rowIndex: Int, isHovered: Bool) -> Color {
    if isHovered { return Color.accentColor.opacity(0.10) }
    return rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
}

/// 根据 hover 与档位绘制 accent 高亮底；描边在浅色主题下也能保持可发现性。
private struct MetadataDrillDownChrome: ViewModifier {
    let isHovered: Bool
    let variant: MetadataDrillDownVariant
    /// 非 nil 时启用斑马纹底（Star Top10 等整行列表）；hover 仍走 accent 高亮。
    let rowIndex: Int?

    /// 显式保留 `rowIndex` 的默认值：`let` 属性自带初值时不会进入合成的 memberwise initializer，
    /// 整行下钻因此无法传入行号；普通数值按钮仍可省略该参数。
    init(isHovered: Bool, variant: MetadataDrillDownVariant, rowIndex: Int? = nil) {
        self.isHovered = isHovered
        self.variant = variant
        self.rowIndex = rowIndex
    }

    private var fillOpacity: Double {
        switch variant {
        case .compact: return isHovered ? 0.16 : 0.10
        case .stat: return isHovered ? 0.14 : 0.08
        case .row: return isHovered ? 0.10 : 0.05
        }
    }

    private var strokeOpacity: Double {
        isHovered ? 0.32 : 0.14
    }

    private var cornerRadius: CGFloat {
        switch variant {
        case .compact: return 5
        case .stat: return 8
        case .row: return 6
        }
    }

    private var horizontalPadding: CGFloat {
        switch variant {
        case .compact: return 6
        case .stat: return 6
        case .row: return 8
        }
    }

    private var verticalPadding: CGFloat {
        switch variant {
        case .compact: return 2
        case .stat: return 6
        case .row: return 5
        }
    }

    private var rowFill: Color {
        if let rowIndex {
            return metadataZebraBackground(rowIndex: rowIndex, isHovered: isHovered)
        }
        return Color.accentColor.opacity(fillOpacity)
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

/// 元数据里的数字/文本下钻按钮。
struct MetadataDrillDownButton<Label: View>: View {
    let help: LocalizedStringKey?
    let variant: MetadataDrillDownVariant
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    init(
        help: LocalizedStringKey? = nil,
        variant: MetadataDrillDownVariant = .compact,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.help = help
        self.variant = variant
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .modifier(MetadataDrillDownChrome(isHovered: isHovered, variant: variant))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
        .help(help ?? "")
    }
}

/// 元数据整行下钻（如 Star Top10）；hover 扫整行，正文保持 primary 色。
struct MetadataDrillDownRowButton<Label: View>: View {
    let help: String?
    /// 传入行号时启用斑马纹底，便于长列表扫描。
    let rowIndex: Int?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    init(
        help: String? = nil,
        rowIndex: Int? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.help = help
        self.rowIndex = rowIndex
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                label()
                if isHovered {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 4)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(MetadataDrillDownChrome(isHovered: isHovered, variant: .row, rowIndex: rowIndex))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
        .help(help ?? "")
    }
}
