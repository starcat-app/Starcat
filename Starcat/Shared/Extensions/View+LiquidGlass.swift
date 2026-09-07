//
//  View+LiquidGlass.swift
//  Starcat
//
//  Centralizes macOS 26 Liquid Glass compatibility boundaries so feature views
//  can keep expressing intent without duplicating availability checks.
//

import SwiftUI

extension View {
    /// Lets macOS 26 render the native Liquid Glass window toolbar while preserving
    /// Starcat's transparent-toolbar appearance on macOS 15 through macOS 25.
    ///
    /// The fallback is intentionally limited to older systems. Hiding the toolbar
    /// background on macOS 26 would suppress the system-provided window chrome and
    /// force each workspace to recreate Liquid Glass manually.
    @ViewBuilder
    func starcatWindowToolbarChrome() -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}
