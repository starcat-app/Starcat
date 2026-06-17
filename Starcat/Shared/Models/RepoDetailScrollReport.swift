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
}
