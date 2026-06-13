// MARK: - XMLEscape
//
// XML 输出的两个转义工具（§22.10 Q9 决议）。
//
// **只有 2 个 escape 点**（其它不需要转义）：
//   1. CDATA 内容 —— 只需处理 `]]>` 序列（终止序列）
//   2. 属性值 —— 5 个标准字符 `& < > " '`
//
// XML 元素之间的纯文本（不在 CDATA 内）我们这里都用 CDATA 包裹，所以不需要 entity escape。
//
// **CDATA 拆段算法**：
//   含 `]]>` 的字符串无法直接放进单个 CDATA 段。业界标准做法是「拆成两个 CDATA 段」：
//     原文：`A ]]> B`
//     替换：`A ]]` + `]]>` + `<![CDATA[` + `> B`
//     即：把 `]]>` 替换为 `]]]]><![CDATA[>` —— 在 `]]` 后关闭第一个 CDATA，
//     新 CDATA 段从 `>` 开始（剩余的 `> B` 在新 CDATA 内）。
//
// 关键不变量：
//   - escapeCDATA(x) 包在 `<![CDATA[...]]>` 里**永远**形成合法的 XML 序列
//   - escapeAttribute(x) 包在 `"..."` 里**永远**形成合法的 XML 属性值

import Foundation

public enum XMLEscape {

    /// CDATA 内容转义。
    ///
    /// 用法：`"<![CDATA[\(XMLEscape.escapeCDATA(text))]]>"`
    public static func escapeCDATA(_ text: String) -> String {
        text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
    }

    /// 属性值转义（5 个标准字符）。
    ///
    /// 用法：`"<file path=\"\(XMLEscape.escapeAttribute(path))\">"`
    public static func escapeAttribute(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")  // **必须**先做（其它替换会引入 `&`）
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
