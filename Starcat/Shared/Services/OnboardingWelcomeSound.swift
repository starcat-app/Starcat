//
//  OnboardingWelcomeSound.swift
//  Starcat
//
//  首次引导「浏览 / 登录 / 跳过」点击后延迟播放，贯穿欢迎收束与主窗口露出的欢迎声效。
//
//  设计意图：
//  - 点击后等待 1s 再播放约 4.8s 的电影感音效，让高潮对齐欢迎画面与主窗口揭示
//  - 资源：`Resources/Sounds/onboarding-welcome.wav`
//
//  关键约束：
//  - 用 AVAudioPlayer（macOS 上比 NSSound 更稳定）；测试 host 内 no-op
//  - 调用方仍在用户点击时立即触发，由本服务统一管理 1s 延迟和重复触发取消
//

import AVFoundation
import Foundation

@MainActor
enum OnboardingWelcomeSound {

    /// 延迟到欢迎画面已经出现后再播放，避免声音抢在视觉收束之前。
    private static let playbackDelay: Duration = .seconds(1)
    /// 播放期间强引用，防止 ARC 提前释放截断尾音。
    private static var player: AVAudioPlayer?
    /// 等待播放的任务；重复触发时必须取消旧任务，避免多段音效排队播放。
    private static var startTask: Task<Void, Never>?
    /// 释放播放器的延迟任务；重复播放时要取消旧任务，避免旧任务把新播放器置空。
    private static var releaseTask: Task<Void, Never>?

    /// 点击「浏览 / 登录 / 跳过」后立即调用，并由服务延迟 1s 播放。
    static func playWelcomeIfAvailable() {
        guard !TestEnvironment.isRunning else { return }

        // Debug 菜单重放引导时可能连续触发。先取消待播任务并停止旧播放器，
        // 保证只有最新一轮动画能在自己的 1s 时间点开始播放。
        startTask?.cancel()
        startTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        player?.stop()
        player = nil

        startTask = Task { @MainActor in
            try? await Task.sleep(for: playbackDelay)
            guard !Task.isCancelled else { return }
            startTask = nil
            playBundledWelcomeSound()
        }
    }

    /// 加载并播放 bundle 内的最终音频；必须仅由延迟任务在主线程调用。
    private static func playBundledWelcomeSound() {
        guard let url = Bundle.main.url(
            forResource: "onboarding-welcome",
            withExtension: "wav"
        ) else {
            AppLog.ui.warning("Onboarding welcome sound missing from bundle (onboarding-welcome.wav)")
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.volume = 1.0
            audioPlayer.numberOfLoops = 0
            audioPlayer.currentTime = 0
            audioPlayer.prepareToPlay()

            guard audioPlayer.play() else {
                AppLog.ui.warning("Onboarding welcome sound play() returned false")
                return
            }

            player = audioPlayer
            AppLog.ui.debug("Onboarding welcome sound playing (\(audioPlayer.duration, privacy: .public)s)")

            releaseTask = Task { @MainActor in
                let hold = audioPlayer.duration + 0.25
                try? await Task.sleep(for: .seconds(hold))
                guard !Task.isCancelled else { return }
                if player === audioPlayer {
                    player = nil
                    releaseTask = nil
                }
            }
        } catch {
            AppLog.ui.warning("Onboarding welcome sound failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
