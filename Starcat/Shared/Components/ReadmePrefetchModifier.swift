//
//  ReadmePrefetchModifier.swift
//  Starcat
//
//  列表 row 鼠标 hover 时的 README 预拉 modifier（HOM-201 P1-1，2026-06-14）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  动机
//  ────────────────────────────────────────────────────────────────────────────
//
//  详情页打开瞬间默认要走一帧 `.loading`，即便缓存命中也得 GRDB 异步读一次。
//  把"读缓存 + 必要时 304 验证"提前到列表 hover 期间，用户实际点击进入时缓存
//  已就绪，详情秒开率显著提升。
//
//  ────────────────────────────────────────────────────────────────────────────
//  关键约束
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **500ms debounce**：用户在列表上快速划过不该触发批量请求；停留 500ms 才认为
//    是"有兴趣"信号。值参考 macOS Finder 文件预览 hover 体感。
//  - **softTtl 短路在 API 层**：本 modifier 只负责"hover → 500ms 后调 trigger"
//    一次；是否真发网络请求由 `ReadmeAPI.prefetch(for:)` /
//    `prefetchTrending(owner:repo:)` 内 `isWithinSoftTtl` 判断（命中 6h 内缓存
//    直接 return 不打 GitHub）。modifier 不知道也不需要知道 TTL 细节。
//  - **取消语义**：hover 离开取消 task；快速 hover 进进出出不会留下空跑的 Task。
//  - **错误吞掉**：prefetch 是预热，失败也不报；用户真进详情时 `loadInternal`
//    走正常 SWR 流程会再尝试一次并显示错误态。
//  - **依赖 P0-3 `ReadmeInflightTracker`**：同 repo 并发 hover 同一行（罕见,
//    但比如多窗口）走 inflight 去重,只发一次实际 GitHub 请求。
//

import SwiftUI

/// 列表 row hover 时的 README 预拉 modifier。
///
/// **使用**:
/// ```swift
/// UnifiedRepoRow(card: card, isSelected: ...)
///     .readmePrefetch {
///         await readmeAPI.prefetch(for: repo)
///     }
/// ```
///
/// 详见文件头注释。
struct ReadmePrefetchModifier: ViewModifier {

    /// hover 500ms 后触发的实际业务；调用方拼合调 `ReadmeAPI.prefetch(for:)` 等。
    let trigger: @Sendable () async -> Void

    /// hover → trigger 的延迟（毫秒）。默认 500ms。
    let debounceMs: UInt64

    /// 当前 in-flight 的 prefetch task；hover 离开时取消，避免无谓请求。
    @State private var hoverTask: Task<Void, Never>?
    @Environment(\.starcatListInteractionSuppressed) private var interactionSuppressed

    func body(content: Content) -> some View {
        content.onHover { hovering in
            // 任意 hover 状态变化都先取消上一个 task：
            // - hover 离开 → 取消等待中的 trigger
            // - 同一 row 再次 hover 进入 → 重新 debounce 500ms（防抖）
            hoverTask?.cancel()
            hoverTask = nil

            guard hovering, !interactionSuppressed else { return }

            hoverTask = Task {
                // Task.sleep 抛 CancellationError 时 try? 直接吃掉，cancellation 路径不打日志
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
                guard !Task.isCancelled else { return }
                await trigger()
            }
        }
        .onChange(of: interactionSuppressed) { _, isSuppressed in
            // 鼠标固定在列表上滚动时会快速跨过大量 row；滚动期间不创建 500ms Task。
            if isSuppressed {
                hoverTask?.cancel()
                hoverTask = nil
            }
        }
    }
}

extension View {
    /// 给列表 row 挂上 README hover prefetch 行为。
    ///
    /// 详见 `ReadmePrefetchModifier` 文件头注释。
    ///
    /// - Parameters:
    ///   - debounceMs: hover → trigger 的延迟（毫秒），默认 500ms。一般不需要改。
    ///   - trigger: hover 满 debounce 后执行的业务 closure。调用方负责拼合
    ///     `ReadmeAPI.prefetch(...)` / `prefetchTrending(...)` 等。
    func readmePrefetch(
        debounceMs: UInt64 = 500,
        _ trigger: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(ReadmePrefetchModifier(trigger: trigger, debounceMs: debounceMs))
    }
}
