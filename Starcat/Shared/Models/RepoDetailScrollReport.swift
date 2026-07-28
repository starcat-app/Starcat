//
//  RepoDetailScrollReport.swift
//  Starcat
//
//  详情页 body slot 向 `RepoDetailScaffold` 上报的滚动度量。
//
//  README（WKWebView）与 Release 时间线（SwiftUI ScrollView）共用同一结构，
//  让 Scaffold 在换算 hero 折叠 progress 时能同时看到 scroll offset 与可滚动余量。
//

import CoreGraphics

/// 详情页内容区滚动上报（offset + 展开 Hero 时的可滚动余量）。
struct RepoDetailScrollReport: Equatable, Sendable {
    /// SwiftUI / WebKit 在同一视觉位置可能持续上报亚像素级几何抖动。
    ///
    /// 这些变化对 Hero 折叠没有可见影响，却会让父视图反复写入 `@State`，
    /// 因此统一把 0.5pt 以内的变化视为同一个布局状态。
    static let geometryTolerance: CGFloat = 0.5

    /// 内容区纵向滚动偏移（≥ 0）。
    let offsetY: CGFloat
    /// Hero 完全展开时，内容超出可视区的纵向距离（`scrollHeight - clientHeight`）。
    ///
    /// `nil` 表示上报方尚未测到（例如 README 仍在 loading）；Scaffold 在余量未知时
    /// 禁止折叠，避免短 README 在度量到达前误触发半折叠振荡。
    let scrollOverflow: CGFloat?

    init(offsetY: CGFloat, scrollOverflow: CGFloat?) {
        self.offsetY = max(offsetY, 0)
        if let scrollOverflow {
            self.scrollOverflow = max(scrollOverflow, 0)
        } else {
            self.scrollOverflow = nil
        }
    }

    /// 判断两个滚动报告是否包含用户可感知的几何变化。
    ///
    /// `onScrollGeometryChange` 使用精确 `Equatable` 比较，Charts 布局中的浮点误差也会触发
    /// action；在上报边界先消除亚像素抖动，避免形成「布局 → 状态 → 再布局」反馈循环。
    func differsMeaningfully(
        from previous: RepoDetailScrollReport,
        tolerance: CGFloat = Self.geometryTolerance
    ) -> Bool {
        let threshold = max(tolerance, 0)
        guard abs(offsetY - previous.offsetY) <= threshold else { return true }

        switch (previous.scrollOverflow, scrollOverflow) {
        case (nil, nil):
            return false
        case let (previous?, current?):
            return abs(current - previous) > threshold
        case (.some, nil), (nil, .some):
            return true
        }
    }
}
