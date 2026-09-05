//
//  AmbientModels.swift
//  Starcat
//
//  Ambient 全屏相册墙的纯值模型。Core 层只描述场景、卡片和单调时钟 deadline，
//  不依赖 SwiftUI / AppKit，确保抽卡与休眠恢复逻辑可以独立单测。
//

import Foundation

/// Ambient v1 提供的两个独立浏览场景。
enum AmbientSceneKind: String, Sendable, CaseIterable {
    case repos
    case owners
}

/// 卡片信息密度的预留枚举。
///
/// v1 固定使用 `minimal`；其余 case 只冻结未来扩展的模型语义，不提前渲染。
enum AmbientDensity: String, Sendable, CaseIterable {
    case minimal
    case info
    case rich
}

/// Engine 和 UI 之间共享的最小展示卡片。
struct AmbientCardModel: Identifiable, Equatable, Sendable {
    let id: String
    let visualKey: String
    let title: String
    let artworkURLString: String?
    let subtitle: String?
    let metadata: [String: String]
}

/// 网格密度与全局换卡节奏。
struct AmbientGridConfig: Equatable, Sendable {
    static let defaultChangeInterval: TimeInterval = 3
    static let defaultFlipDuration: TimeInterval = 0.8
    static let defaultInitialLeadIn: TimeInterval = 2

    var rowCount: Int
    var columnCount: Int
    var changeInterval: TimeInterval
    var flipDuration: TimeInterval
    var initialLeadIn: TimeInterval

    init(
        rowCount: Int,
        columnCount: Int,
        changeInterval: TimeInterval = Self.defaultChangeInterval,
        flipDuration: TimeInterval = Self.defaultFlipDuration,
        initialLeadIn: TimeInterval = Self.defaultInitialLeadIn
    ) {
        self.rowCount = rowCount
        self.columnCount = columnCount

        // 全局换卡间隔必须严格长于单次翻转，保证下一格开始前上一格已经落稳。
        let safeFlipDuration = max(0, flipDuration)
        self.flipDuration = safeFlipDuration
        self.changeInterval = max(changeInterval, safeFlipDuration + 0.001)
        self.initialLeadIn = max(1, initialLeadIn)
    }

    /// 非正行列不创建槽位；避免异常 geometry 触发负数容量或整数溢出。
    var slotCount: Int {
        guard rowCount > 0, columnCount > 0 else { return 0 }
        let (count, overflow) = rowCount.multipliedReportingOverflow(by: columnCount)
        return overflow ? 0 : count
    }
}

/// 从 SwiftUI 实际内容区域推导出的 Engine 与图片请求身份。
struct AmbientGridLayout: Equatable, Sendable {
    let config: AmbientGridConfig
    let tilePointSize: Double
    let displayScale: Double

    init(config: AmbientGridConfig, tilePointSize: Double, displayScale: Double) {
        self.config = config
        self.tilePointSize = max(1, tilePointSize)
        self.displayScale = max(1, displayScale)
    }
}

/// 单个稳定槽位的只读快照。
struct AmbientSlotSnapshot: Identifiable, Equatable, Sendable {
    let id: Int
    let card: AmbientCardModel?
    let nextCard: AmbientCardModel?
}

/// Engine 一次推进后的完整 UI 投影。
struct AmbientAdvanceResult: Equatable, Sendable {
    let snapshots: [AmbientSlotSnapshot]
    let changedSlotIDs: Set<Int>
    let nextDeadline: TimeInterval?

    var didChange: Bool {
        !changedSlotIDs.isEmpty
    }
}
