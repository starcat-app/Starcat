//
//  CommitHashLink.swift
//  Starcat
//
//  GitHub commit short SHA 可点击链接组件 —— 在 AI 摘要 footer 等位置使用。
//
//  ┌──────────────────────────────────────────────────────────────────┐
//  │ 为什么必须单独抽组件                                              │
//  ├──────────────────────────────────────────────────────────────────┤
//  │ macOS SwiftUI 的 `Link(_:destination:)` **string-based init**     │
//  │ 内部用私有 `_LinkLabel` 装饰链，自动提供:                          │
//  │   - hover 下划线                                                  │
//  │   - 手型指针 cursor                                               │
//  │   - tint 着色                                                     │
//  │   - VoiceOver "链接" role + click 行为                            │
//  │                                                                    │
//  │ 一旦改用 **closure-based init** `Link(destination:){ Text(...) }`，│
//  │ 自定义 label 会**绕过私有装饰链**，只剩 tint 着色 + 点击行为：     │
//  │   - hover 时**没有**下划线                                        │
//  │   - 鼠标**不变**手型指针                                          │
//  │   - .help tooltip 因为用户不知道哪里能 hover 而难以触发           │
//  │                                                                    │
//  │ 实测路径（dong4j 2026-06-15 02:43 / 10:44 / 10:53 三次反馈链）：  │
//  │   1. 02:43 截图："基于 6e76ed1 ... hash 改成超链接跳 GitHub"      │
//  │   2. 10:44 反馈："没有系统蓝" → 给 label Text 加 .tint            │
//  │      → 颜色修了，但仍是 closure-based Link，hover 装饰仍丢失      │
//  │   3. 10:53 反馈："hover 没下划线 / 没手型 / 没 tooltip"           │
//  │      → 最终方案 = 保留 Link 包壳让点击+VoiceOver+键盘导航免费，  │
//  │        手动重补三件套：onHover + underline + pointerStyle(.link)  │
//  │                                                                    │
//  │ 为什么不直接 string-based init?                                    │
//  │   - 因为父级 footer 已经设了 `.foregroundStyle(.secondary)`,      │
//  │     `Link(meta.commitShaShort, destination:...)` 的 _LinkLabel    │
//  │     会被外层 .secondary 染灰，重新撞回 10:44 "没有系统蓝"老问题。 │
//  │     必须用 closure-based 才能在 label 内显式 `.tint` 覆盖。       │
//  │   - 显式 `.tint` + 手动 hover 装饰，看起来与 string-based Link    │
//  │     视觉一致，且不受外层 foregroundStyle 影响。                    │
//  └──────────────────────────────────────────────────────────────────┘
//
//  使用：
//    CommitHashLink(
//        shortSha: meta.commitShaShort,
//        destination: GitHubURLs.repoCommit(owner:..., repo:..., sha:...)
//    )
//
//  字体跟随父级（默认 caption2.monospaced），如果父级未设字体应主动设置：
//    .font(.caption2)  // 或其它
//

import SwiftUI

/// 可点击的 commit short SHA 链接，hover 时显示下划线 + 手型指针。
///
/// 与父级 `Link` 装饰逻辑：手动重补 macOS `_LinkLabel` 私有装饰的三件套
/// （hover 下划线 / 手型指针 / 显式 tint），同时保留 `Link` 外壳让点击 +
/// VoiceOver 链接 role + 键盘 Tab 导航免费。
///
/// 字体设为 `.caption2.monospaced()` —— commit sha 是 hex 字符串，等宽体
/// 更易扫读；调用方需要其它字号时，外层加 `.font(_:)` 即可被本组件继承。
struct CommitHashLink: View {

    /// 展示用的 short sha（如 `6e76ed1`，通常取 prefix(7)）。
    let shortSha: String

    /// 点击目标 URL。建议传 `GitHubURLs.repoCommit(owner:repo:sha:)` 用 full sha
    /// 而非 short sha，避免 GitHub 302 重定向 + 大仓库碰撞风险。
    let destination: URL

    @State private var isHovered: Bool = false

    var body: some View {
        Link(destination: destination) {
            Text(shortSha)
                .font(.caption2.monospaced())
                // 显式 `.tint`(accent 色)覆盖父级可能存在的 `.foregroundStyle(...)`
                // —— footer 容器外层设了 `.secondary` 会让 Link label 默认 tint 失效
                // （上方文件头注释路径 #2 修复）。`.tint` 而非 `.blue`：① 适配明暗主题
                // ② 跟随用户系统 accent 设置 ③ macOS 网页链接色约定。
                .foregroundStyle(.tint)
                // hover 下划线 —— `_LinkLabel` 私有装饰链丢失后用 .underline(_:)
                // 手动补。SwiftUI 1+ Text 就支持 `.underline(Bool)` 重载。
                .underline(isHovered)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        // macOS 15+ 显式手型指针 —— 替代 `_LinkLabel` 私有装饰自带的 link cursor。
        // 不用 AppKit `NSCursor.pointingHand.push()/pop()` 的原因：cursor 栈在
        // view 销毁时容易卡住手型，SwiftUI 原生 modifier 由系统管理生命周期。
        .pointerStyle(.link)
        .help("ai.assistant.summary.footer.contextMeta.commit.help")
    }
}

#Preview("浅色 - 浅色 secondary 容器") {
    HStack(spacing: 4) {
        Text("基于")
        CommitHashLink(
            shortSha: "6e76ed1",
            destination: URL(string: "https://github.com/foo/bar/commit/6e76ed1abc")!
        )
        Text("(28028 tokens · 437 files)")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding()
}

#Preview("深色 - 浅色 secondary 容器") {
    HStack(spacing: 4) {
        Text("Based on")
        CommitHashLink(
            shortSha: "6e76ed1",
            destination: URL(string: "https://github.com/foo/bar/commit/6e76ed1abc")!
        )
        Text("(28028 tokens · 437 files)")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding()
    .preferredColorScheme(.dark)
}
