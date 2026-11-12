//
//  DirectUpdateLocalization.swift
//  Starcat
//
//  把应用语言偏好接入 Sparkle 的原生文案和内嵌更新说明。
//  不改变进程语言、版本选择、签名校验或安装流程。
//

import Foundation

#if canImport(Sparkle)
import ObjectiveC.runtime
import Sparkle
#endif

/// 更新窗口的语言解析；每次查询偏好，保证下次打开窗口时无需重启应用。
enum DirectUpdateLocalization {
    /// 与 LocaleStore 共用持久化键，避免从任意线程访问 MainActor 状态。
    static let preferenceKey = "AppLocaleOverride"

    /// 显式选择优先于系统语言；英文是 Sparkle 缺少某种翻译时的最终回退。
    static func preferredLanguages(
        preferences: UserDefaults = .standard,
        systemLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        let selection = preferences.string(forKey: preferenceKey)
        let languages = selection.map { $0 == "system" ? systemLanguages : [$0] } ?? systemLanguages
        return languages + (languages.contains("en") ? [] : ["en"])
    }

    /// Sparkle 以 zh_CN / zh_TW 命名翻译，交给 Foundation 匹配应用的 BCP-47 标识。
    static func resourceBundle(
        in bundle: Bundle,
        preferences: UserDefaults = .standard,
        systemLanguages: [String] = Locale.preferredLanguages
    ) -> Bundle? {
        // Sparkle 的英文原文位于 Base.lproj，没有 en.lproj；显式英文必须选 Base，
        // 否则系统中文可能再次成为框架的默认语言。
        let languages = bundle.localizations.filter { $0 != "Base" } + ["en"]
        let language = Bundle.preferredLocalizations(
            from: languages,
            forPreferences: preferredLanguages(preferences: preferences, systemLanguages: systemLanguages)
        ).first ?? "en"
        let directory = language == "en" ? "Base" : language
        guard let path = bundle.path(forResource: directory, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// 官网目前维护中英文日志；中文语言使用中文，其余使用英文原文。
    static func releaseNotes(
        in properties: [AnyHashable: Any],
        preferences: UserDefaults = .standard,
        systemLanguages: [String] = Locale.preferredLanguages
    ) -> String? {
        let language = preferredLanguages(preferences: preferences, systemLanguages: systemLanguages).first ?? "en"
        let notesLanguage = Locale(identifier: language).language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        guard let notes = properties["starcat:releaseNotes-\(notesLanguage)"] as? String,
              !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return notes
    }

    /// 在创建 updater 前安装一次，仅作用于 Sparkle 自身的显示路径。
    static func install() {
        #if canImport(Sparkle)
        _ = installation
        #endif
    }

    #if canImport(Sparkle)
    private static let installation: Void = {
        guard let original = class_getInstanceMethod(SUAppcastItem.self, #selector(getter: SUAppcastItem.itemDescription)),
              let localized = class_getInstanceMethod(SUAppcastItem.self, #selector(SUAppcastItem.starcatLocalizedItemDescription)) else {
            assertionFailure("Sparkle release notes localization hook is unavailable")
            return
        }

        // 与主应用既有 LocalizedBundle 相同，只替换框架 bundle 单实例，
        // 不替换 Foundation 的全局语言匹配，也不影响其他依赖的 bundle。
        object_setClass(Bundle(for: SPUUpdater.self), DirectUpdateLocalizedBundle.self)

        // Sparkle 在解析 XML 时按进程语言丢弃其他 description。只桥接公开的
        // 显示 getter，从保留在 propertiesDictionary 的扩展字段选择应用语言。
        // item 的类型、编码、签名和下载信息均保持 Sparkle 原来的实现。
        method_exchangeImplementations(original, localized)
    }()
    #endif
}

#if canImport(Sparkle)
/// 仅为 Sparkle 框架查询对应语言的原生字符串表。
private final class DirectUpdateLocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let localized = DirectUpdateLocalization.resourceBundle(in: self) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return localized.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension SUAppcastItem {
    /// 只调整内嵌说明的读取，旧 feed 没有扩展字段时仍使用 Sparkle 原始正文。
    @objc fileprivate dynamic func starcatLocalizedItemDescription() -> String? {
        DirectUpdateLocalization.releaseNotes(in: propertiesDictionary) ?? starcatLocalizedItemDescription()
    }
}
#endif
