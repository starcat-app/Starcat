//
//  OnboardingWelcomeSound.swift
//  Starcat
//
//  首次引导「开始使用 / 跳过」点击瞬间起，贯穿退出动画直至主窗口露出的欢迎声效。
//
//  设计意图：
//  - 五音渐强上行（G4→C6），约 3.2s，覆盖「收起 → 欢迎 → 淡出」大部分时长
//  - 资源：`Resources/Sounds/onboarding-welcome.wav`
//
//  关键约束：
//  - 用 AVAudioPlayer（macOS 上比 NSSound 更稳定）；测试 host 内 no-op
//  - 必须在用户点击「开始使用 / 跳过」时**立即**调用，不要等 welcome 画面切换后再播
//

import AVFoundation
import Foundation

enum OnboardingWelcomeSound {

    /// 播放期间强引用，防止 ARC 提前释放截断尾音。
    private static var player: AVAudioPlayer?

    /// 点击「开始使用 / 跳过」后立即调用。
    static func playWelcomeIfAvailable() {
        guard !TestEnvironment.isRunning else { return }

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
            audioPlayer.prepareToPlay()

            guard audioPlayer.play() else {
                AppLog.ui.warning("Onboarding welcome sound play() returned false")
                return
            }

            player = audioPlayer
            AppLog.ui.debug("Onboarding welcome sound playing (\(audioPlayer.duration, privacy: .public)s)")

            Task { @MainActor in
                let hold = audioPlayer.duration + 0.25
                try? await Task.sleep(for: .seconds(hold))
                if player === audioPlayer {
                    player = nil
                }
            }
        } catch {
            AppLog.ui.warning("Onboarding welcome sound failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
