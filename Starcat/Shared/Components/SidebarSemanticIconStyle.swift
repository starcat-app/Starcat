//
//  SidebarSemanticIconStyle.swift
//  Starcat
//
//  侧栏语义色图标：未选中保留品牌/分类色；明亮主题选中时跟系统蓝底反成白色。
//
//  设计约束：
//  - 必须走 `ShapeStyle.resolve(backgroundProminence)`，不能手写 `selection == item`。
//    macOS List 蓝底高亮与 binding 写入不同步（按下即高亮、抬起才写 binding；
//    切换 section 重建时还会让旧行卡在「选中白」直到数据加载触发重绘）。
//  - 黑暗主题语义色本身够亮，不改。
//

import SwiftUI

/// 侧栏图标色：未选中用语义色；明亮主题选中时跟系统蓝底反成白色。
struct SidebarSemanticIconStyle: ShapeStyle {
    let semanticColor: Color

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if environment.backgroundProminence == .increased, environment.colorScheme == .light {
            return AnyShapeStyle(.white)
        }
        return AnyShapeStyle(semanticColor)
    }
}
