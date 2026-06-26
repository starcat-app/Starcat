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
    private static let reservedShortcuts: Set<KeyboardShortcutConfiguration> = [
        .init(key: "i", command: true, option: false, control: false, shift: false),
        .init(key: ",", command: true, option: false, control: false, shift: false),
        .init(key: "a", command: true, option: false, control: false, shift: false),
        .init(key: "m", command: true, option: false, control: false, shift: true)
    ]
}

extension KeyboardShortcutConfiguration: Hashable {}
