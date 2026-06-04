//
//  MarkdownHeadingDemoter.swift
//  Starcat
//
//  AI 助手对话回复 Markdown 标题智能降级（HOM-150 dong4j 2026-06-04 16:05 反馈）。
//
//  模块职责：
//  - 把 AI 助手聊天回复里的 Markdown 标题统一降级到 H3 起步，避免与 AI 助手窗口
//    里"角色标头 ## 👤 / ## 🤖 AI"撞同级别；
//  - 仅作用于 AI 聊天回复的渲染层（`AIChatBubble` 显示 + `RepoAIChatViewModel`
//    导出完整对话），AI 摘要面板不动——摘要是"独立文档"，H1/H2 在那个语境下
//    本就该有最大权重。
//
//  关键约束（dong4j 原话："不是简单的降级, 是要先判断"）：
//  - 先扫一遍找最高级别 `minLevel`（数字最小）；
//  - **只有** `minLevel <= 2` 时才整体平移 `shift = 3 - minLevel`，所有标题级别
//    `+ shift`，但上限 H6（GFM 规范，超过 6 个 `#` 不再是 ATX 标题）；
//    - H1 → H3（shift = 2），H2 → H3 / H3 → H4 / H4 → H5 / H5 → H6 / H6 → H6
//    - H2 → H3（shift = 1），H3 → H4 / H4 → H5 / H5 → H6 / H6 → H6
//  - 若 `minLevel >= 3`，**原样返回不改一字节**——回答已经是 H3 起步，再降反而
//    把所有 sub-heading 压扁到 H6 不可读。
//  - 跳过 fenced code block 内部行（` ``` ` / `~~~` 围栏）：里面的 `#` 多半是
//    shell 注释 / Python `#!` shebang / Markdown 教学示例，绝不能误当 ATX 标题。
//  - 只识别 ATX 标题（行首 `#{1,6}` + 空白 + 内容），不处理 Setext（`===` / `---`
//    下划线式标题）：AI 输出几乎只用 ATX；Setext 要往后看一行才能判定，性价比低。
//  - 行首 7+ 个 `#` 不算 ATX；裸 `#` 后不跟空白也不算（如 `#tag` 不是标题）。
//
//  性能：两遍扫，O(n) 字符；内部 String 拷贝只在真正需要降级时发生。流式中
//  AI bubble 每个 token 重渲一次也只是几 KB markdown，完全可以接受。
//

import Foundation

enum MarkdownHeadingDemoter {

    /// 按需把 markdown 字符串里的所有 ATX 标题降级到至少 H3 起步。
    ///
    /// 详细规则见文件头注释；当不需要降级时返回**同一字符串实例**不做拷贝。
    static func demoteToH3(_ markdown: String) -> String {
        guard !markdown.isEmpty else { return markdown }

        let lines = markdown.components(separatedBy: "\n")

        // ---- Pass 1：扫最高标题级别 ----
        var minLevel = 7  // 哨兵值，> 6 表示"没找到任何 ATX 标题"或"不需要降级"
        var inFence = false
        for line in lines {
            if isFenceLine(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let level = atxLevel(of: line), level < minLevel {
                minLevel = level
            }
        }

        // 无标题，或最高级别已是 H3+：原样返回（dong4j："要先判断"）。
        guard minLevel <= 2 else { return markdown }

        let shift = 3 - minLevel  // H1→2, H2→1

        // ---- Pass 2：应用降级 ----
        var result: [String] = []
        result.reserveCapacity(lines.count)
        inFence = false
        for line in lines {
            if isFenceLine(line) {
                inFence.toggle()
                result.append(line)
                continue
            }
            if inFence {
                result.append(line)
                continue
            }
            if let level = atxLevel(of: line) {
                let newLevel = min(level + shift, 6)
                result.append(replaceLeadingHashes(in: line, originalCount: level, newCount: newLevel))
            } else {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    // MARK: - 内部识别工具

    /// 是否是 fenced code block 围栏行（` ``` ` 或 `~~~`）。
    ///
    /// GFM 规则：行首 0~3 个空白 + 至少 3 个相同的 ` ` ` 或 `~`。4 个以上空白属于
    /// indented code block 规则，不算围栏。可选的 info-string（如 ` ```swift `）
    /// 不影响判定，我们只看是否进入 / 退出围栏状态。
    private static func isFenceLine(_ line: String) -> Bool {
        var idx = line.startIndex
        var spaceCount = 0
        while idx < line.endIndex, line[idx] == " " {
            spaceCount += 1
            if spaceCount > 3 { return false }  // 4+ 空白 → indented code，不算围栏
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return false }
        let fenceChar = line[idx]
        guard fenceChar == "`" || fenceChar == "~" else { return false }
        var count = 0
        while idx < line.endIndex, line[idx] == fenceChar {
            count += 1
            idx = line.index(after: idx)
        }
        return count >= 3
    }

    /// 若行是 ATX 标题，返回级别（1~6），否则 nil。
    ///
    /// 容忍行首 0~3 个空白（GFM 兼容），不容忍 4+ 空白（属代码块缩进）。
    private static func atxLevel(of line: String) -> Int? {
        var idx = line.startIndex
        var leadingSpaces = 0
        while idx < line.endIndex, line[idx] == " " {
            leadingSpaces += 1
            if leadingSpaces > 3 { return nil }  // 4+ 空白属代码块缩进，不是 ATX
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == "#" else { return nil }

        var hashCount = 0
        while idx < line.endIndex, line[idx] == "#" {
            hashCount += 1
            if hashCount > 6 { return nil }  // 超过 6 个 # 立刻否决
            idx = line.index(after: idx)
        }
        guard (1...6).contains(hashCount) else { return nil }
        // 行末紧跟（裸 `#####` 在 GFM 是合法空标题）—— 也算
        if idx == line.endIndex { return hashCount }
        // # 段后必须紧跟空白才是标题（避免误判 `#tag` / `#!shebang`）
        let next = line[idx]
        guard next == " " || next == "\t" else { return nil }
        return hashCount
    }

    /// 把行首的 `#{originalCount}` 替换为 `#{newCount}`，保留前导空白与 # 后内容。
    private static func replaceLeadingHashes(in line: String, originalCount: Int, newCount: Int) -> String {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " {
            idx = line.index(after: idx)
        }
        // idx 现在指向第一个 #
        let hashEnd = line.index(idx, offsetBy: originalCount)
        let leading = line[..<idx]
        let trailing = line[hashEnd...]
        return String(leading) + String(repeating: "#", count: newCount) + String(trailing)
    }
}
