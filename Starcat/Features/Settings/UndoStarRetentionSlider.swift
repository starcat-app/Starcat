//
//  UndoStarRetentionSlider.swift
//  Starcat
//
//  Undo Star 保留时间滑杆组件（2026-07-05）。
//
//  5 个节点等距排列（占满滑杆），各段刻度不同：
//  1天 ── 7天/1周 ── 4周/28天 ── 12月/365天 ── 永久(-1)
//    ←每天1格→ ←每周1格→  ←每月1格→   ←每年1格→
//

import SwiftUI

/// 滑杆节点定义
private struct RetentionNode: Identifiable {
    let id: Int
    let days: Int          // -1 = 永久
    let label: String      // 显示标签
    let tickUnit: Int      // 该段每个刻度代表多少天
}

private let nodes: [RetentionNode] = [
    RetentionNode(id: 0, days: 1,    label: "1天",   tickUnit: 1),
    RetentionNode(id: 1, days: 7,    label: "1周",   tickUnit: 7),
    RetentionNode(id: 2, days: 28,   label: "4周",   tickUnit: 30),
    RetentionNode(id: 3, days: 365,  label: "12月",  tickUnit: 365),
    RetentionNode(id: 4, days: -1,   label: "永久",  tickUnit: 365),
]

/// 等距节点位置（0.0, 0.25, 0.5, 0.75, 1.0）
private let segmentSize: Double = 0.25

/// retentionDays → 滑杆位置
private func daysToPosition(_ days: Int) -> Double {
    if days <= 0 { return 1.0 }  // 永久
    for i in 0..<(nodes.count - 1) {
        let from = nodes[i].days
        let to = nodes[i + 1].days
        if to < 0 { break }  // 到永久节点
        if days >= from && days <= to {
            let basePos = Double(i) * segmentSize
            let progress = min(Double(days - from) / Double(to - from), 1.0)
            return basePos + progress * segmentSize
        }
    }
    return 1.0  // 超过 365 → 永久
}

/// 滑杆位置 → retentionDays
private func positionToDays(_ position: Double) -> Int {
    let p = max(0, min(1, position))
    if p >= 0.999 { return -1 }  // 永久
    if p >= 0.75 { return 365 }  // 12月
    let segment = min(Int(p / segmentSize), 3)
    let segmentProgress = (p - Double(segment) * segmentSize) / segmentSize

    let from = nodes[segment].days
    let to = nodes[segment + 1].days
    let tickUnit = nodes[segment].tickUnit

    let rawDays = Double(from) + segmentProgress * Double(to - from)
    let snapped = floor(rawDays / Double(tickUnit)) * Double(tickUnit)
    return max(from, min(to, Int(snapped)))
}

/// 格式化当前天数显示
private func formatDays(_ days: Int) -> String {
    if days <= 0 { return "永久" }
    if days < 7 { return "\(days)天" }
    if days < 30 {
        let w = days / 7
        let d = days % 7
        return d > 0 ? "\(w)周\(d)天" : "\(w)周"
    }
    if days < 365 {
        let m = days / 30
        let r = days % 30
        let w = r / 7
        let d = r % 7
        var parts: [String] = []
        if m > 0 { parts.append("\(m)月") }
        if w > 0 { parts.append("\(w)周") }
        if d > 0 { parts.append("\(d)天") }
        return parts.joined()
    }
    return "12月"
}

// MARK: - Slider View

struct UndoStarRetentionSlider: View {
    @Binding var retentionDays: Int

    /// 拖拽过程中的临时值
    @State private var dragValue: Double = 0
    /// 是否正在拖拽
    @State private var isDragging: Bool = false

    /// 缩短保留时间确认弹窗
    @State private var showShortenConfirm = false
    @State private var pendingDays: Int = 0

    /// 立即删除确认弹窗
    @State private var showDeleteNowConfirm = false

    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标签
            HStack {
                Text("settings.undoStar.retention")
                    .font(.body)
                Spacer()
                Text(isDragging ? formatDays(positionToDays(dragValue)) : formatDays(retentionDays))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            // 节点标记
            HStack(spacing: 0) {
                ForEach(nodes) { node in
                    Text(node.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: node.id == nodes.count - 1 ? .trailing : node.id == 0 ? .leading : .center)
                }
            }

            // 滑杆
            Slider(
                value: $dragValue,
                in: 0...1,
                onEditingChanged: { editing in
                    isDragging = editing
                    if editing {
                        // 开始拖拽：校准初始值
                        dragValue = daysToPosition(retentionDays)
                    } else {
                        // 松手：判断是否需要弹窗
                        let newDays = positionToDays(dragValue)
                        if newDays < retentionDays {
                            // 缩短 → 弹窗确认
                            pendingDays = newDays
                            showShortenConfirm = true
                        } else if newDays > retentionDays {
                            // 延长 → 直接生效
                            retentionDays = newDays
                        }
                        // 相等则不处理
                    }
                }
            )
            .controlSize(.large)
            .onAppear {
                dragValue = daysToPosition(retentionDays)
            }

            // 立即删除按钮
            HStack {
                Spacer()
                Button(role: .destructive) {
                    showDeleteNowConfirm = true
                } label: {
                    Label("settings.undoStar.deleteNow", systemImage: "trash")
                }
                .disabled(dependencies.undoStarCleanupScheduler.isCleaning)
                .help("settings.undoStar.deleteNow.help")
            }
            .padding(.top, 12)
        }
        // 缩短确认弹窗
        .alert("settings.undoStar.shortenTitle", isPresented: $showShortenConfirm) {
            Button("settings.undoStar.shortenCancel", role: .cancel) {
                // 恢复滑杆位置到原值
                dragValue = daysToPosition(retentionDays)
            }
            Button("settings.undoStar.shortenDelete", role: .destructive) {
                retentionDays = pendingDays
                dragValue = daysToPosition(pendingDays)
                Task { await dependencies.undoStarCleanupScheduler.cleanupNow() }
            }
        } message: {
            Text("settings.undoStar.shortenMessage")
        }
        // 立即删除确认弹窗
        .alert("settings.undoStar.deleteNowTitle", isPresented: $showDeleteNowConfirm) {
            Button("settings.undoStar.deleteNowCancel", role: .cancel) {}
            Button("settings.undoStar.deleteNowConfirm", role: .destructive) {
                Task { await dependencies.undoStarCleanupScheduler.cleanupNow() }
            }
        } message: {
            Text("settings.undoStar.deleteNowMessage")
        }
    }
}
