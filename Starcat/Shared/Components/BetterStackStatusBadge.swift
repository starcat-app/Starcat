//
//  BetterStackStatusBadge.swift
//  Starcat
//
//  Better Stack embeddable monitor uptime 徽标（远程 SVG → 栅格化 Image）。
//
//  设计要点：
//  - Better Stack 以 `image/svg+xml` + `Cache-Control: no-cache` 提供徽标，语义等同 README
//    里的 `<img src="...svg">`；本组件用 VectorImage 在 macOS 上异步拉取并渲染。
//  - 官方尺寸 80×20 pt；栅格化 options 与展示 frame 对齐，避免 Retina 发糊。
//  - Tab 可见期间每 60s 递增 `reloadID` 强制重拉，贴近 Better Stack 服务端刷新节奏。
//
//  关键约束：
//  - 加载中 / 失败时不占位 spinner（caption 行高度需稳定），失败时留透明占位或直接折叠。
//  - 点击整枚徽标跳转 Better Stack 状态页（由调用方传入 linkURL）。
//

import SwiftUI
import VectorImageUI

struct BetterStackStatusBadge: View {

    let badgeURL: URL
    let linkURL: URL

    /// Better Stack monitor badge 固定尺寸（SVG viewBox 80×20）。
    private static let badgeSize = CGSize(width: 80, height: 20)

    /// `reloadID` 变化时 VectorImage 会重新拉取 SVG（绕过 URL 不变时的内存缓存）。
    @State private var reloadID = 0

    var body: some View {
        Link(destination: linkURL) {
            VectorImageAsyncImage(
                url: badgeURL,
                options: .init(size: Self.badgeSize),
                reloadID: reloadID
            ) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: Self.badgeSize.width, height: Self.badgeSize.height)
                } else if phase.error != nil {
                    // 网络失败时折叠占位，避免 caption 行出现空白条
                    EmptyView()
                } else {
                    Color.clear
                        .frame(width: Self.badgeSize.width, height: Self.badgeSize.height)
                }
            }
        }
        .help(Text("settings.services.status"))
        .task {
            // 首次加载由 VectorImageAsyncImage 自行触发；此处只负责周期性 refresh。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                reloadID += 1
            }
        }
    }
}
