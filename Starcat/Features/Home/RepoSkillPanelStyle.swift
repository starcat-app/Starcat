//
//  RepoSkillPanelStyle.swift
//  Starcat
//
//  安装工作区的卡片层级，遵循 DESIGN.md 的明暗表面对比。
//

import SwiftUI

enum RepoSkillPanelStyle {
    static func panelColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.17) : Color.white
    }
}
