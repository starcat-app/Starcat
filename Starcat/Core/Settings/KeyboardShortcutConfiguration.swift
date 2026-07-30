//
//  KeyboardShortcutConfiguration.swift
//  Starcat
//
//  用户可配置快捷键的持久化值对象。
//
//  关键约束：
//  - 只接受至少一个修饰键 + 单个英文字母或数字，避免吞掉正常文本输入；
//  - 存储键值而不是 NSEvent keyCode，保证不同键盘布局和重启后的语义稳定；
//  - 应用内已占用组合在统一校验入口拒绝，设置页和测试共用同一规则。
//

import AppKit
import SwiftUI

struct KeyboardShortcutConfiguration: Codable, Equatable, Sendable {
    var key: String
    var command: Bool
    var option: Bool
    var control: Bool
    var shift: Bool

    static let globalSearchDefault = KeyboardShortcutConfiguration(
        key: "k",
        command: true,
        option: false,
        control: false,
        shift: false
    )

    /// 列表 toolbar 常规搜索（SmartSearchField）默认 Command+F。
    static let regularSearchDefault = KeyboardShortcutConfiguration(
        key: "f",
        command: true,
        option: false,
        control: false,
        shift: false
    )

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(key))
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if command { result.insert(.command) }
        if option { result.insert(.option) }
        if control { result.insert(.control) }
        if shift { result.insert(.shift) }
        return result
    }

    /// SwiftUI 菜单 / 隐藏按钮使用的可选快捷键值。
    /// 调用方通过传入 `nil` 只移除键盘触发，不影响 Button 本身是否可点击。
    var swiftUIShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    var displayText: String {
        var value = ""
        if control { value += "⌃" }
        if option { value += "⌥" }
        if shift { value += "⇧" }
        if command { value += "⌘" }
        return value + key.uppercased()
    }

    enum ValidationError: Equatable {
        case invalidKey
        case missingModifier
        case reserved
        case duplicateConfiguredAction
    }

    var validationError: ValidationError? {
        guard key.count == 1,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return .invalidKey
        }
        // Shift 单独搭配字母仍等价于正常输入大写字符，不能注册为全局入口。
        // 至少要求 Command / Option / Control 之一；Shift 只作为附加修饰键。
        guard command || option || control else { return .missingModifier }
        guard !Self.reservedShortcuts.contains(self) else { return .reserved }
        return nil
    }

    /// 在固定键位校验之外，再检查同一设置分组内的其他可配置动作。
    ///
    /// 这里不把另一项搜索快捷键并入全局保留集合，因为 `⌘K` / `⌘F` 本身都允许
    /// 用户重新分配；只有候选值与当前另一项完全相同时才构成冲突。
    func validationError(
        conflictingWith configuredShortcuts: Set<KeyboardShortcutConfiguration>
    ) -> ValidationError? {
        if let validationError { return validationError }
        return configuredShortcuts.contains(self) ? .duplicateConfiguredAction : nil
    }

    static func make(from event: NSEvent) -> KeyboardShortcutConfiguration? {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else {
            return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyboardShortcutConfiguration(
            key: characters,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift)
        )
    }

    /// 当前应用已有固定语义，不允许搜索入口覆盖。
    private static let reservedShortcuts = StarcatShortcutCatalog.fixedReserved
}

extension KeyboardShortcutConfiguration: Hashable {}

/// 可配置应用命令的默认键位目录。
///
/// 默认值、恢复操作和测试都读取这里，避免同一个动作在不同入口漂移出多个键位。
/// 用户实际选择由 `AppSettings` 持久化；这里不保存运行时状态。
enum StarcatShortcutCatalog {
    /// `⌘R` 表达“刷新当前上下文”，具体落到中栏列表还是右栏详情由命令路由判断。
    static let refreshCurrentContentDefault = KeyboardShortcutConfiguration(
        key: "r", command: true, option: false, control: false, shift: false
    )
    static let openKnowledgeRAGDefault = KeyboardShortcutConfiguration(
        key: "k", command: true, option: false, control: false, shift: true
    )
    static let openSelectedRepoAIDefault = KeyboardShortcutConfiguration(
        key: "a", command: true, option: false, control: false, shift: true
    )

    /// 只有不可由用户改写的系统 / 上下文语义留在保留集合。
    /// 五个可配置动作通过设置页的完整冲突矩阵互斥，不能把它们放进这里，
    /// 否则动作自己的默认值也会被录制器判定为非法。
    static let fixedReserved: Set<KeyboardShortcutConfiguration> = [
        .init(key: ",", command: true, option: false, control: false, shift: false),
        .init(key: "a", command: true, option: false, control: false, shift: false),
        .init(key: "m", command: true, option: false, control: false, shift: true)
    ]
}
