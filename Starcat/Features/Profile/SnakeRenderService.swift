//
//  SnakeRenderService.swift
//  Starcat
//
//  贡献草坪贪吃蛇动画的后台驱动。
//
//  整条动画管线（时钟 + 帧计算 + CGContext 渲染）跑在后台 detached Task 上，
//  只把渲染好的 CGImage 通过 `DispatchQueue.main.async` 发布回主线程（SwiftUI 只主线程读）。
//  这样切换模块/分类时，主线程的视图重建不会打断动画的时钟和渲染。
//
//  为什么用「@MainActor 类 + Task.detached 循环 + DispatchQueue.main.async」：
//  - 帧计算要碰 animator（已声明 Sendable）、渲染是纯函数，适合后台；Task.detached 让
//    循环脱离主 actor，主线程卡顿不挡 tick。
//  - 发布回主线程用 `DispatchQueue.main.async`：Swift 6 里它的闭包天然是 @MainActor，
//    内部 `self.frameImage = image` 是合法的主 actor 访问，不触发隔离检查。
//  - 曾踩坑（不要回退）：用 DispatchSourceTimer 的后台 handler（@convention(block)，
//    非 @Sendable）里写 `Task { @MainActor }` 或碰 @MainActor 的 self，会在后台队列触发
//    `_swift_task_checkIsolatedSwift` 运行期 trap（SIGTRAP）。Task.detached + @MainActor
//    闭包是编译期静态保证，不会再崩。
//

import SwiftUI

/// 贡献草坪贪吃蛇动画的后台驱动（@MainActor 对外，重活在后台 detached Task）。
@MainActor
@Observable
final class SnakeRenderService {

    /// 当前帧渲染结果（后台渲染，主线程写、主线程读）。
    private(set) var frameImage: CGImage?

    /// 时钟 Task 不参与 UI 观察，排除出 @Observable 的跟踪。
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    /// 启动 / 重启动画。
    /// animator 为 nil（off 玩法 / 数据未到 / reduceMotion / 宿主暂停）时只渲染一次静态草坪。
    func configure(
        animator: SnakeAnimator?,
        payload: ContributionCalendarPayload?,
        colorScheme: ColorScheme
    ) {
        stop()

        guard let animator else {
            renderStatic(payload: payload, colorScheme: colorScheme)
            return
        }

        // 后台动画循环：时钟 + 算帧 + 渲染全在 detached Task（后台），
        // 发布用 fire-and-forget 的 DispatchQueue.main.async，不阻塞循环 → 不依赖主线程。
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }  // 服务已释放 → 循环自终止
                let date = Date()
                let frame: AnimationFrame
                if let step = animator.currentStep(at: date) {
                    frame = animator.frame(at: step)
                } else {
                    // 处于「轮间暂停」：渲染完整草坪、不画蛇。
                    frame = .empty
                }
                let image = SnakeFrameRenderer.render(
                    payload: payload,
                    frame: frame,
                    colorScheme: colorScheme
                )
                DispatchQueue.main.async {
                    self.frameImage = image
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stop() {
        renderTask?.cancel()
        renderTask = nil
    }

    /// 渲染一次静态草坪（无蛇、无食物）。只渲染一次（非逐帧），主线程 2-3ms 可接受。
    private func renderStatic(payload: ContributionCalendarPayload?, colorScheme: ColorScheme) {
        frameImage = SnakeFrameRenderer.render(
            payload: payload,
            frame: .empty,
            colorScheme: colorScheme
        )
    }
}
