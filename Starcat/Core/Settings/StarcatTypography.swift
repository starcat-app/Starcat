//
//  StarcatTypography.swift
//  Starcat
//
//  Starcat UI typography tokens shared by the main window, Agent workspace,
//  and Knowledge RAG workspace.
//

import SwiftUI

/// Typography tokens from the root `DESIGN.md`.
///
/// The point sizes below are the standard-density baseline. User-facing
/// scaling still flows through `InterfaceScale`, so the main window and both
/// workspaces stay aligned when the user changes the interface size setting.
enum StarcatTypography {
    case workspaceTitle
    case panelTitle
    case rowTitle
    case bodyEmphasis
    case body
    case input
    case caption
    case captionStrong
    case captionSmall
    case code
    case iconSmall
    case iconMedium
    case iconLarge

    var pointSize: CGFloat {
        switch self {
        case .workspaceTitle: return 20
        case .panelTitle:     return 17
        case .rowTitle:       return 15
        case .bodyEmphasis:   return 14
        case .body:           return 13
        case .input:          return 16
        case .caption:        return 12
        case .captionStrong:  return 12
        case .captionSmall:   return 11
        case .code:           return 12
        case .iconSmall:      return 13
        case .iconMedium:     return 15
        case .iconLarge:      return 18
        }
    }

    var defaultWeight: Font.Weight? {
        switch self {
        case .workspaceTitle, .panelTitle, .rowTitle, .captionStrong:
            return .semibold
        case .bodyEmphasis, .iconSmall, .iconMedium, .iconLarge:
            return .medium
        default:
            return nil
        }
    }

    var defaultDesign: Font.Design {
        switch self {
        case .code:
            return .monospaced
        default:
            return .default
        }
    }
}

extension InterfaceScale {
    /// Generates a SwiftUI font from Starcat's shared typography tokens.
    ///
    /// Keep this as a thin wrapper over `font(size:weight:design:)` so legacy
    /// call sites can be migrated incrementally without introducing a second
    /// scaling path.
    func font(
        _ token: StarcatTypography,
        weight: Font.Weight? = nil,
        design: Font.Design? = nil
    ) -> Font {
        font(
            size: token.pointSize,
            weight: weight ?? token.defaultWeight,
            design: design ?? token.defaultDesign
        )
    }
}
