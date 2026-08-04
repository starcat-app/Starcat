//
//  AIComposerKeyboardPolicy.swift
//  Starcat
//
//  RAG 与 Agent 输入框共享的 Return / Command-Return 解释规则。
//

import AppKit

enum AIComposerKeyboardAction: Equatable {
    case send
    case insertNewline
}

enum AIComposerKeyboardPolicy {
    /// 设置开启时 Cmd+Return 发送；关闭时普通 Return 发送。另一组合始终插入换行。
    static func action(
        for modifiers: NSEvent.ModifierFlags,
        requiresCommandReturn: Bool
    ) -> AIComposerKeyboardAction {
        let usesCommand = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        return usesCommand == requiresCommandReturn ? .send : .insertNewline
    }
}
