//
//  DiagnosticReportEvidence.swift
//  Starcat
//
//  诊断报告的采集预览：区分无记录、记录不完整与采集不可用，不推断应用健康状态。
//

import Foundation

/// 预览统计原始保留证据，不使用会排除“已忽略提醒”的状态面板计数。
enum DiagnosticReportEvidence: Equatable, Sendable {
    case loading
    case available(count: Int, incomplete: Bool)
    case unavailable

    /// 与常规导出同取最近 24 小时；损坏行和存储失败不能显示成“没有故障”。
    static func read(_ snapshot: DiagnosticSnapshot?, since: Date) -> Self {
        guard let snapshot else { return .unavailable }
        var incomplete = snapshot.health.contains {
            ($0.key.hasSuffix("Failures") || ["damagedLines", "captureUnavailable", "droppedEvents"].contains($0.key))
                && $0.value > 0
        }
        var count = 0
        let decoder = JSONDecoder()
        for line in snapshot.text.split(separator: "\n") {
            guard let event = try? decoder.decode(DiagnosticEvent.self, from: Data(line.utf8)) else {
                incomplete = true
                continue
            }
            if event.isSevereFailure, event.date >= since { count += 1 }
        }
        return .available(count: count, incomplete: incomplete)
    }
}
