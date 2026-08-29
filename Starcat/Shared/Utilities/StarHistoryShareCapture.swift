//
//  StarHistoryShareCapture.swift
//  Starcat
//
//  Star 趋势卡片「复制图片」的导出态开关。
//
//  屏幕上的卡片和剪贴板里的图共用同一套 `starHistorySection`。导出态只藏操作按钮
//  和限制说明，不另画一张营销图。Environment 留给独立子树读取；`RepositoryInsightsView`
//  的 computed view 仍要显式传 Bool——它读的是父视图环境，套在副本上的
//  `.environment` 进不去。
//

import SwiftUI

private struct StarHistoryShareCaptureKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` 表示当前树正在为剪贴板渲染，不要画分享 / 刷新 / 限制链接。
    var starHistoryShareCapture: Bool {
        get { self[StarHistoryShareCaptureKey.self] }
        set { self[StarHistoryShareCaptureKey.self] = newValue }
    }
}

/// 导出态要藏哪些 chrome。抽成纯函数，方便单测，避免在 SwiftUI 里断言「按钮不在」。
enum StarHistoryShareCaptureChrome {
    /// 分享和刷新是操作入口，截进图里没有意义。
    static func showsActionButtons(_ isCapturing: Bool) -> Bool {
        !isCapturing
    }

    /// 「为何没有 GitHub 精确历史？」是页面帮助链接，不属于分享图内容。
    static func showsRestrictionLink(_ isCapturing: Bool, allowedByPolicy: Bool) -> Bool {
        !isCapturing && allowedByPolicy
    }

    /// 悬停十字线和读数浮层只服务交互，导出时清掉以免带上瞬时状态。
    static func showsChartSelection(_ isCapturing: Bool) -> Bool {
        !isCapturing
    }

    /// 仓库名和 logo 只进剪贴板图；屏幕上的卡片已在仓库详情上下文里。
    static func showsRepositoryIdentity(_ isCapturing: Bool) -> Bool {
        isCapturing
    }
}
