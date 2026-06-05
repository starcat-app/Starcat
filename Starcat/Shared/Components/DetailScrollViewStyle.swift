//
//  DetailScrollViewStyle.swift
//  Starcat
//
//  右侧详情页 SwiftUI ScrollView 的原生滚动条样式收口。
//
//  设计约束：
//  - Repo 列表使用 macOS 原生 List，滚动条由系统 NSScroller 控制。
//  - 详情页里少量 SwiftUI ScrollView 也应该使用同一类 overlay scroller，
//    避免和 README WebView / List 的滚动条视觉口径分裂。
//  - SwiftUI 没有暴露 NSScrollView.scrollerStyle，因此只用一个不可见 NSViewRepresentable
//    找到最近的 NSScrollView，并做最小 AppKit 配置。
//

import SwiftUI
import AppKit

extension View {
    /// 让详情页中的 SwiftUI ScrollView 使用和 repo 列表一致的原生 overlay 滚动条口径。
    ///
    /// 注意：此 modifier 应挂在 `ScrollView` 本身上；README 使用 WKWebView 自己的 CSS 滚动条，
    /// 不经过这里。
    func detailScrollViewStyle() -> some View {
        background(DetailScrollViewConfigurator())
    }
}

/// 不可见的 AppKit 探针：进入视图层级后向上找到最近的 NSScrollView 并配置滚动条。
///
/// 这里不保存 NSScrollView 引用。SwiftUI 可能重建宿主视图，按生命周期重新探测更稳。
private struct DetailScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureScrollView(containing: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureScrollView(containing: nsView)
        }
    }

    private func configureScrollView(containing view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }
}
