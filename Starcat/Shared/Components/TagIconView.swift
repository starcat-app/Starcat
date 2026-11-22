//
//  TagIconView.swift
//  Starcat
//
//  统一渲染标签的系统符号和内置素材，复用各展示面的图标尺寸与配色。
//

import SwiftUI

/// 模板素材继承所在视图的前景色，品牌素材按原色展示。
struct TagIconView: View {
    let identifier: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var fallback: String = "tag.fill"

    var body: some View {
        Group {
            if let entry = TagIconCatalog.entry(for: identifier), let image = entry.image {
                Image(nsImage: image)
                    .renderingMode(entry.isTemplate ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: TagIconCatalog.systemName(for: identifier, fallback: fallback))
                    .font(.system(size: size, weight: weight))
            }
        }
        .accessibilityHidden(true)
    }
}
