//
//  AgentRuntimeSettingsStatus.swift
//  Starcat
//
//  Agent Runtime 设置页共享的轻量检测状态。
//

import Foundation

/// 描述一次本地 Runtime 配置检测的生命周期。
///
/// 状态只表达设置页的本地检查结果，不代表模型请求已经成功；尤其 Codex 的认证
/// 仍由 Codex CLI 自己管理，避免 Starcat 读取或复制其登录凭据。
enum AgentRuntimeSettingsStatus: Equatable {
    case idle
    case checking
    case ready
    case failed(String)

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}
