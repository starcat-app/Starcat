//
//  DiagnosticBreadcrumb.swift
//  Starcat
//
//  只随最终严重故障导出的安全阶段；每个操作最多保留最近十六条，
//  不构建全局操作历史，也不保存请求或用户正文。
//

import Foundation

/// 阶段耗时相对所属根操作开始；关联标识只在真实请求提供时出现。
struct DiagnosticBreadcrumb: Codable, Sendable, Equatable {
    static let limit = 16
    var phase: String
    var outcome: DiagnosticEvent.Outcome?
    var elapsedMs: Double
    var operationID: String?
    var parentOperationID: String?
    var requestID: String?
    var serverTraceID: String?
    var service: String?
    var statusCode: Int?
    var errorCode: String?
    var fields: [String: DiagnosticValue]

    /// 复用事件的字段白名单，内存上下文与最终落盘遵守同一隐私边界。
    init(event: DiagnosticEvent, elapsedMs: Double) {
        phase = event.phase.flatMap(DiagnosticEvent.safeTrace) ?? "stage"
        outcome = event.outcome
        self.elapsedMs = elapsedMs.isFinite ? max(0, elapsedMs) : 0
        operationID = event.operationID.flatMap(DiagnosticEvent.safeTrace)
        parentOperationID = event.parentOperationID.flatMap(DiagnosticEvent.safeTrace)
        requestID = event.requestID.flatMap(DiagnosticEvent.safeTrace)
        serverTraceID = event.serverTraceID.flatMap(DiagnosticEvent.safeTrace)
        service = event.service.flatMap(DiagnosticEvent.safeTrace)
        statusCode = event.statusCode
        errorCode = event.errorCode.flatMap(DiagnosticEvent.safeTrace)
        fields = DiagnosticEvent.safeFields(event.fields)
    }

    /// 导出时重新验证自管文件，防止手工改写 JSON 扩大采集范围。
    var sanitized: Self {
        let event = DiagnosticEvent(level: .info, category: "diagnostics", operation: "breadcrumb",
            message: "Operation stage", service: service, statusCode: statusCode, errorCode: errorCode,
            operationID: operationID, parentOperationID: parentOperationID,
            requestID: requestID, serverTraceID: serverTraceID, phase: phase, outcome: outcome,
            fields: fields)
        return Self(event: event, elapsedMs: elapsedMs)
    }
}
