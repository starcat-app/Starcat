//
//  RuntimeContextProvider.swift
//  Starcat
//
//  把 App 运行环境信息（当前 UTC 时间 / 周几 / 用户时区 / Starcat 版本）拼成
//  markdown 块字符串，作为 AI Chat system prompt 的 `{runtimeContext}` 占位符值。
//
//  关键设计（dong4j 2026-06-15 拍板）：
//
//  1. **UTC 时间精度到「整点」**（`2026-06-15T07:00Z`）：
//     - 同一小时内 system prompt 字符串完全相同 → 服务端 prompt cache 不 miss；
//     - AI 回答"现在几点"对小时级精度足够（用户问的是时段，不是秒表）；
//     - 不用 ISO 8601 标准的 hour-only 写法（`2026-06-15T07Z`），因为 LLM 训练
//       语料里这种格式罕见，容易被误解。改用「分钟字段补零」(`07:00`) 的伪精度
//       表达，cache 命中等价但 LLM 友好。
//
//  2. **不输出本地时间，只给 UTC + 时区**：刻意保留 AI 的时区换算环节，验证 LLM
//     时区推理顺便降低重复信息。AI 拿到 `Asia/Shanghai (UTC+8)` + `07:00Z`
//     自己能算出本地 `15:00`。
//
//  3. **周几按用户时区算，不按 UTC**：周几是给人用的概念，UTC 周几对用户没意义
//     （例：UTC 周一晚 23:00 = 用户这边周二早 07:00，用户脑子里就是周二）。
//     显式标 `Day of week (user timezone)` 防 AI 误解。
//
//  4. **周几用英文** ("Monday" / "Tuesday" / ...) **而非本地化字符串**：整段
//     system prompt 是英文，混 `星期一` 中文不一致；AI 会按 `{outputLanguage}`
//     翻译输出回给用户。**硬编码英文 7 元数组**而非读 `Calendar.weekdaySymbols`，
//     原因：后者本地化输出依赖 `Calendar.locale`，在 zh-Hans 环境会返回 `星期一`；
//     强行设 `Locale(identifier: "en_US_POSIX")` 也行，但硬编码更 deterministic、
//     无需为 locale 兼容性写测试。
//
//  5. **静态函数 + 测试注入点**：
//     - `snapshot()` 生产路径，无参，读 `Date() / .current / .main`；
//     - `_snapshotForTesting(now:timeZone:bundle:)` 测试注入 deterministic 值。
//     不用 instance + DI 是因为本组件零状态，纯函数最简单。
//

import Foundation

/// AI Chat system prompt 注入的「运行环境」占位符生成器。
///
/// 不可实例化，只暴露静态方法。调用方：`RepoAIInsightService.buildChatSystemPrompt`。
enum RuntimeContextProvider {

    /// 生成 runtimeContext markdown 块字符串。
    ///
    /// 调用约定：`RepoAIInsightService.buildChatSystemPrompt` 每次组装 chat
    /// system prompt 时调用一次，结果塞进 `{runtimeContext}` 占位符。
    /// 返回值已是渲染好的 4 行 markdown 列表，调用方直接当字符串值用。
    ///
    /// 性能：纯字符串拼接 + Bundle 读取，调用一次约几微秒，无 I/O，可在 actor
    /// hot path 直接调用。
    static func snapshot() -> String {
        _snapshotForTesting(
            now: Date(),
            timeZone: .current,
            infoDictionary: Bundle.main.infoDictionary
        )
    }

    /// 测试用注入点。生产路径走 `snapshot()`，不直接调本函数。
    ///
    /// - Parameters:
    ///   - now: 当前时刻，测试可注入 deterministic Date。
    ///   - timeZone: 用户时区，测试可注入 `TimeZone(identifier: "Asia/Shanghai")`
    ///     等已知值。生产为 `.current`。
    ///   - infoDictionary: 读 `CFBundleShortVersionString` / `CFBundleVersion`
    ///     的 dict。测试直接构造 `[String: Any]` 注入；生产为 `Bundle.main.infoDictionary`。
    ///     传 dict 而非 `Bundle` 是因为 `Bundle.infoDictionary` 是只读 stored property，
    ///     子类无法 override，mock 成本高；dict 接口零成本。
    nonisolated static func _snapshotForTesting(
        now: Date,
        timeZone: TimeZone,
        infoDictionary: [String: Any]?
    ) -> String {
        let utcString = formatUTCToHour(now)
        let weekday = englishWeekday(for: now, in: timeZone)
        let timeZoneString = formatTimeZone(timeZone, at: now)
        let version = infoString(infoDictionary, key: "CFBundleShortVersionString") ?? "?"
        let build = infoString(infoDictionary, key: "CFBundleVersion") ?? "?"

        return """
        - Current UTC time: \(utcString) (ISO 8601, hour precision)
        - Day of week (user timezone): \(weekday)
        - User timezone: \(timeZoneString)
        - Starcat version: \(version) (build \(build))
        """
    }

    // MARK: - Private helpers

    /// UTC 时间格式化到「整点」：`2026-06-15T07:00Z`。
    ///
    /// - 用 `DateFormatter` + 显式 `yyyy-MM-dd'T'HH':00Z'` pattern 而非 ISO8601DateFormatter +
    ///   后处理去掉秒：前者直接产出目标字符串，无需正则裁剪；
    /// - **locale 必须 `en_US_POSIX`**：防止 zh_Hans 等 locale 走 Buddhist / Imperial
    ///   日历产生 `2569-06-15` 这种灾难性输出。即便 macOS 默认 Gregorian，POSIX 是工业
    ///   标准的"防御性必加"；
    /// - **分钟字段硬编码 `:00`**：不是真的把分钟数算出来——本函数语义就是「整点字符串」，
    ///   不需要分钟数据。这样同一小时内任意 `Date` 入参输出完全相同 → 服务端 prompt
    ///   cache 命中。
    private static func formatUTCToHour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH':00Z'"
        return formatter.string(from: date)
    }

    /// 计算用户时区下的英文周几。
    ///
    /// `Calendar.component(.weekday, from:)` 返回 1-7（1 = Sunday，Gregorian 默认）。
    /// 硬编码英文 7 元数组而非 `Calendar.weekdaySymbols`，避免 locale 本地化输出
    /// （详见文件头第 4 点设计说明）。
    private static func englishWeekday(for date: Date, in timeZone: TimeZone) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekdayIndex = calendar.component(.weekday, from: date) - 1
        guard (0..<names.count).contains(weekdayIndex) else {
            // 防御性兜底：理论上 Gregorian .weekday 只可能 1-7，这里 unreachable，
            // 但万一 Apple 改了语义至少不崩。
            return "Unknown"
        }
        return names[weekdayIndex]
    }

    /// 时区字符串：`Asia/Shanghai (UTC+8)` 或 `Asia/Kathmandu (UTC+5:45)`。
    ///
    /// - `secondsFromGMT(for:)` 取此刻偏移（支持 DST，例：纽约夏令时 UTC-4 / 冬令时 UTC-5）；
    /// - 大多数时区是整小时偏移，但有 30 / 45 分钟偏移的（如印度 +5:30、尼泊尔 +5:45），
    ///   分支处理以输出正确的 `UTC±H:MM` 形式。
    private static func formatTimeZone(_ timeZone: TimeZone, at date: Date) -> String {
        let id = timeZone.identifier
        let offsetSeconds = timeZone.secondsFromGMT(for: date)
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absSeconds = abs(offsetSeconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        let offsetString: String
        if minutes == 0 {
            offsetString = "UTC\(sign)\(hours)"
        } else {
            offsetString = String(format: "UTC%@%d:%02d", sign, hours, minutes)
        }
        return "\(id) (\(offsetString))"
    }

    /// 从 infoDictionary 取字符串值，空字符串视为缺失。
    ///
    /// 兜底原因：`CFBundleShortVersionString` / `CFBundleVersion` 在测试 host /
    /// CI 环境里可能缺失或为空，调用方拿 `"?"` 比拿空字符串更好排错。
    private static func infoString(_ info: [String: Any]?, key: String) -> String? {
        guard let value = info?[key] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}
