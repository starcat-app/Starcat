//
//  RAGExecutionTraceReducer.swift
//  Starcat
//
//  把 Service 执行事件投影成时间线步骤。嵌套思考不能沿用「新步骤开始 = 结束全部 running」。
//

import Foundation

/// 时间线步骤的事件归约。ViewModel 只负责把结果同步到当前会话，不在这里分叉完成规则。
enum RAGExecutionTraceReducer {
    /// 追加一个新步骤。顶层步骤会结束当前 running 的父步骤；嵌套思考不会。
    static func applyStarted(
        _ kind: RAGExecutionStepKind,
        to steps: inout [RAGExecutionStep],
        at time: Date = .now
    ) {
        if !kind.nestsInsideCurrentPhase {
            for index in steps.indices where steps[index].state == .running {
                steps[index].state = .completed
                if steps[index].completedAt == nil {
                    steps[index].completedAt = time
                }
            }
        }
        steps.append(RAGExecutionStep(kind: kind, startedAt: time))
    }
}
