//
//  RepoSkillSkeletonView.swift
//  Starcat
//
//  Skills 列表与阅读区的加载占位；共用现有扫光时钟、主题配色和减少动态效果策略。
//

import SwiftUI

/// 只描绘占位布局，不持有加载任务；显示与退场由调用方的真实就绪状态控制。
struct RepoSkillSkeletonView: View {
    enum Layout {
        case selection, manifest, files, tree
    }

    let layout: Layout

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    private let selectionRowCount = 12

    private var selectionHeight: CGFloat {
        interfaceScale.scaled(RepoSkillRowChrome.rowHeight) * CGFloat(selectionRowCount)
            + RepoSkillRowChrome.rowSpacing * CGFloat(selectionRowCount - 1)
    }

    var body: some View {
        Group {
            if layout == .manifest {
                ReadmeSkeletonView(backgroundColor: RepoSkillPanelStyle.panelColor(colorScheme))
            } else {
                SkeletonAnimatedPhase { phase in
                    let palette = SkeletonPalette.forColorScheme(colorScheme)
                    GeometryReader { geometry in
                        if layout == .selection {
                            selectionRows(width: geometry.size.width, phase: phase, palette: palette)
                        } else {
                            attachmentRows(width: geometry.size.width, phase: phase, palette: palette)
                        }
                    }
                }
            }
        }
        .frame(height: layout == .selection ? selectionHeight : nil)
        .frame(maxWidth: .infinity, maxHeight: layout == .selection ? nil : .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 与真实列表共用行高、复选框、monogram 和斑马纹，骨架不挤动即将出现的列表。
    private func selectionRows(width: CGFloat, phase: Double, palette: SkeletonPalette) -> some View {
        let checkboxSize: CGFloat = 14
        let monogramSize = interfaceScale.scaled(RepoSkillRowChrome.monogramSize)
        let insets = 2 * (RepoSkillRowChrome.horizontalInset + RepoSkillRowChrome.itemSpacing)
        let textWidth = max(0, width - insets - checkboxSize - monogramSize)
        let fractions: [CGFloat] = [0.88, 0.66, 0.94, 0.76]
        return VStack(spacing: RepoSkillRowChrome.rowSpacing) {
            ForEach(0..<selectionRowCount) { index in
                HStack(spacing: RepoSkillRowChrome.itemSpacing) {
                    SkeletonBlock(
                        width: checkboxSize, height: checkboxSize, cornerRadius: 4, phase: phase, palette: palette
                    )
                    SkeletonBlock(
                        width: monogramSize, height: monogramSize, cornerRadius: RepoSkillRowChrome.monogramCornerRadius,
                        phase: phase, palette: palette
                    )
                    SkeletonBlock(
                        width: textWidth * fractions[index % fractions.count],
                        height: interfaceScale.scaled(12), phase: phase, palette: palette
                    )
                }
                .padding(.horizontal, RepoSkillRowChrome.horizontalInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: interfaceScale.scaled(RepoSkillRowChrome.rowHeight))
                .background(
                    RepoSkillRowChrome.background(rowIndex: index, isSelected: false, isHovered: false),
                    in: RoundedRectangle(cornerRadius: RepoSkillRowChrome.rowCornerRadius, style: .continuous)
                )
            }
        }
    }

    /// 文件保留大小列，目录保留缩进；不展示可点击的假文件，也不让占位参与滚动。
    private func attachmentRows(width: CGFloat, phase: Double, palette: SkeletonPalette) -> some View {
        let contentWidth = max(0, width - 36)
        let fractions: [CGFloat] = [0.72, 0.52, 0.84, 0.64]
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: layout == .tree ? 10 : 0) {
                ForEach(0..<10) { index in
                    let indent: CGFloat = layout == .tree && index > 0 ? (index.isMultiple(of: 4) ? 8 : 36) : 0
                    HStack(spacing: 10) {
                        SkeletonBlock(width: 14, height: 14, phase: phase, palette: palette)
                        SkeletonBlock(
                            width: max(0, contentWidth - indent - (layout == .files ? 68 : 24))
                                * fractions[index % fractions.count],
                            height: interfaceScale.scaled(11), phase: phase, palette: palette
                        )
                        Spacer(minLength: 0)
                        if layout == .files {
                            SkeletonBlock(width: 34, height: 10, phase: phase, palette: palette)
                        }
                    }
                    .padding(.leading, indent)
                    .padding(.vertical, layout == .files ? 10 : 0)
                    if layout == .files {
                        Divider()
                    }
                }
            }
            .padding(18)
        }
        .scrollDisabled(true)
        .background(RepoSkillPanelStyle.panelColor(colorScheme))
    }
}
