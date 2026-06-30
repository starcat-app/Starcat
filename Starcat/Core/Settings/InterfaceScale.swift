//
//  InterfaceScale.swift
//  Starcat
//
//  应用内字号 / 显示密度档位。
//
//  Starcat 是信息密度较高的 macOS 三栏工具。这里不提供连续滑杆，而是提供少量
//  离散档位，避免用户把列表行高、toolbar、卡片和弹窗调到不可控的组合。
//

import SwiftUI

/// 用户可选的界面字号档位。
///
/// 当前用于 Agent Workspace 与主窗口核心三栏。后续继续接入新页面时，应逐个页面验证布局，
/// 而不是一次性把全站所有 `Font` 直接乘同一个比例。
enum InterfaceScale: String, CaseIterable, Identifiable {
    case compact
    case standard
    case comfortable
    case large

    var id: String { rawValue }

    /// 字号倍率。数值保持保守，避免 macOS 桌面工具在大字档下丢失信息密度。
    var multiplier: CGFloat {
        switch self {
        case .compact:     return 0.92
        case .standard:    return 1.00
        case .comfortable: return 1.08
        case .large:       return 1.16
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .compact:     return "settings.general.interfaceScale.compact"
        case .standard:    return "settings.general.interfaceScale.standard"
        case .comfortable: return "settings.general.interfaceScale.comfortable"
        case .large:       return "settings.general.interfaceScale.large"
        }
    }
}

private struct StarcatInterfaceScaleKey: EnvironmentKey {
    static let defaultValue: InterfaceScale = .standard
}

extension EnvironmentValues {
    /// 应用内界面字号档位。先作为可渐进接入的环境值，不强制全站立即适配。
    var starcatInterfaceScale: InterfaceScale {
        get { self[StarcatInterfaceScaleKey.self] }
        set { self[StarcatInterfaceScaleKey.self] = newValue }
    }
}

extension InterfaceScale {
    /// 按当前界面字号档位缩放一个显式点值。
    ///
    /// 主界面已有大量手工调过的 `13pt / 12pt / 10pt` 点值；全局字号接入时应以
    /// 这些现状作为 `.standard` 基线，再乘档位倍率。这样标准档完全保持当前主窗口视觉。
    func scaled(_ pointSize: CGFloat) -> CGFloat {
        pointSize * multiplier
    }

    /// 生成按界面字号档位缩放的 SwiftUI Font。
    func font(
        size pointSize: CGFloat,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        Font.system(size: scaled(pointSize), weight: weight, design: design)
    }
}
