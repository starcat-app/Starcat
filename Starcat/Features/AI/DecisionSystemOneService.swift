//
//  DecisionSystemOneService.swift
//  Starcat
//
//  CLI / MCP / HTTP 共用的 Jev `/v1/systemone` 兼容执行器。
//
//  设计约束:
//  - 请求协议只做传输层归一化，不复制业务决策逻辑；真正的引擎选择、兜底
//    约束和回答校验仍然收口在 `DecisionEngineProviding` 实现里。
//  - `state` 用 MCP Value 承载，保持 Jev 原始 JSON 语义；App 侧业务习惯使用
//    `DecisionState`，但在公开契约里不强制要求仓库字段。
//  - `model` 只是 Jev SDK 兼容字段。用户不通过外部入口指定业务模型；引擎内部
//    继续使用设置页保存的固定模型 ID，避免任意客户端驱动可计费模型。
//  - 服务开关、Pro 门控和写入权限由入口共享检查；本执行器只检查所选引擎当前
//    是否可用，失败后直接上抛，不新增跨引擎兜底。
//

import Foundation
import MCP

extension DecisionSystemOneInput {
    /// MCP arguments 先回到 JSON，再复用 Jev / CLI / HTTP 共用的严格解码契约。
    static func decode(from value: Value) throws -> DecisionSystemOneInput {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

/// 进程内唯一的结构化决策公开执行器。
@MainActor
final class DecisionSystemOneService {
    private let engineRegistry: DecisionEngineRegistry
    private let settings: AppSettings

    init(engineRegistry: DecisionEngineRegistry, settings: AppSettings) {
        self.engineRegistry = engineRegistry
        self.settings = settings
    }

    /// 执行一次外部决策请求并返回 Jev 兼容响应。
    ///
    /// MCP Value 会先转成 JSON，再走 DTO 解码；这样 `state` 可以是对象、数组或
    /// 字符串，而不必为每个入口复制 JSON 转换逻辑。
    func evaluate(_ input: DecisionSystemOneInput) async throws -> DecisionEvaluationResponse {
        guard settings.decisionEngineEnabled else {
            throw DecisionEngineError.engineUnavailable(.jev, reason: "Decision engine is disabled in Settings")
        }

        let selectedID = settings.decisionEngineID
        guard let engine = engineRegistry.engine(for: selectedID) else {
            throw DecisionEngineError.engineNotRegistered(selectedID)
        }
        switch engine.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw DecisionEngineError.engineUnavailable(selectedID, reason: reason)
        }

        let request = try input.evaluationRequest()
        return try await engine.evaluate(request)
    }
}
