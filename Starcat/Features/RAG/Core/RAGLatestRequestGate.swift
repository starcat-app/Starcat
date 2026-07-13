//
//  RAGLatestRequestGate.swift
//  Starcat
//
//  RAG 异步选择请求的最新结果门闩。
//
//  关键约束：底层数据库或索引读取不一定会及时响应取消；因此除了取消 Task，还必须
//  在写回 UI 前校验 generation，避免先点 A、再点 B 时较慢的 A 覆盖 B。
//

import Foundation

/// 以递增 token 表示“当前仍有效的异步请求”。
///
/// 该类型由 MainActor 上的 ViewModel 使用，不承担 Task 生命周期；调用方仍应取消可
/// 取消的 Task。这里专门覆盖取消不合作或已经返回的旧请求，保持 UI 选择一致。
@MainActor
final class RAGLatestRequestGate {
    private var latestGeneration = 0

    /// 开始一个新请求，并使此前返回的 token 失效。
    func begin() -> Int {
        latestGeneration &+= 1
        return latestGeneration
    }

    /// 只有最新请求才可以提交异步读取结果。
    func isCurrent(_ generation: Int) -> Bool {
        generation == latestGeneration
    }
}
