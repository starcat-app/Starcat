//
//  RepoFileIcon.swift
//  Starcat
//
//  文件类型图标的局部绘制策略。保留 Devicon 原色以区分技术栈，
//  全局 BusinessIcon 继续保持模板色，不影响菜单、工具栏和其他列表。
//

import SwiftUI

/// 文件名始终由旁边的文本表达，图标本身不重复朗读。
struct RepoFileIcon: View {
    let name: String
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let source = RepoFileTypeIcon.iconSource(forFileName: name)
        Group {
            if case .asset(let asset) = source, !asset.hasPrefix("Business"), NSImage(named: asset) != nil {
                Image(asset)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    // 深色单色品牌在暗背景上需要浅底承托，不能全局反转品牌色。
                    .padding(2)
                    .background(colorScheme == .dark ? Color.white.opacity(0.88) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 3))
            } else {
                BusinessIcon(
                    source: source.isAsset && NSImage(named: assetName(source)) == nil ? .business(.file) : source,
                    pointSize: interfaceScale.scaled(size)
                )
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: interfaceScale.scaled(size), height: interfaceScale.scaled(size))
        .accessibilityHidden(true)
    }

    private func assetName(_ source: BusinessIcon.Source) -> String {
        if case .asset(let name) = source { return name }
        return ""
    }
}
