//
//  GithubAuthView.swift
//  Starcat
//
//  GitHub 登录页（Device Flow） · V2 视觉升级版（2026-06-03 上线）。
//
//  设计参考 dong4j 提供的 Radian 风格截图：卡片式布局 + 顶部 hero 视觉插图 +
//  标题 / 副标题 + 全宽主按钮 + 暖色渐变 user_code 卡片。
//
//  2026-06-17：旧版 `GithubAuthViewLegacy` 已删除（V2 生产路径稳定后不再保留回滚副本）。
//  与早期 Legacy 版的主要差异：
//  - 视觉：卡片 / 圆角 / 暖色渐变 code 卡，旧版是平铺式系统控件
//  - awaitingCode 交互：
//      · 点 code 主区 → 复制 + 切到 "✓ 已复制" + 1.5s 后自动开浏览器
//      · 点右侧图标   → 复制 + 切到 "✓ 已复制" + 1.5s 后复位（不开浏览器）
//  - 5 个状态：idle / connecting / awaitingCode / authenticated / error，过渡有 smooth 动画
//  - authenticated 态显示 0.6s 成功反馈再 dismiss，避免"瞬间消失"的迷惑感
//
//  状态映射（AuthSession.state + isAuthenticating + lastError → 5 个 UI 态）：
//  ┌───────────────────────────────────────────────────────────┬──────────────┐
//  │ .unauthenticated  &&  !isAuthenticating  &&  lastError=nil│ idle         │
//  │ .unauthenticated  &&  !isAuthenticating  &&  lastError≠nil│ error        │
//  │ .unauthenticated  &&  isAuthenticating                    │ connecting   │
//  │ .awaitingUserCode(info)                                   │ awaitingCode │
//  │ .authenticated                                            │ authenticated│
//  └───────────────────────────────────────────────────────────┴──────────────┘
//
//  按钮统一样式：所有大按钮走 `bigButton(...)` helper，统一圆角 8 + 14pt 垂直 padding，
//  避免系统 borderedProminent / bordered 圆角不一致的视觉割裂。
//
//  关键约束：
//  - 所有用户可见文本走 String Catalog `authV2.*` 键（保留 V2 前缀避免跟 Legacy 的 `auth.*` 冲突）
//  - 所有 `.buttonStyle(.plain)` 必须紧跟 `.focusEffectDisabled()`（项目强制规则）
//  - `copyResetTask` 必须在所有"关闭 / 取消 / 切换"场景 cancel，避免野 Task 1.5s 后误开浏览器
//

import SwiftUI
import AppKit

struct GithubAuthView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(\.dismiss) private var dismiss
    /// 2026-06-15:auth 卡片状态切换 0.28s smooth 动画在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// awaitingCode 态 code 卡片的复制反馈状态机。
    /// - `.idle`：等待用户操作
    /// - `.copiedAndOpening`：点了主区域,已复制,1.5s 后会自动开浏览器
    /// - `.copiedSilent`：点了右侧独立图标,已复制,1.5s 后仅复位(不会开浏览器)
    ///
    /// 两个 "copied" 态视觉完全相同（`isCopied == true`），用户看到的都是 "✓ 已复制"，
    /// 仅在副作用上区分（是否到时间后开浏览器）。
    @State private var copyFeedback: CopyFeedback = .idle

    /// 反馈复位的延时 task（主流程 1.5s 后开浏览器并复位 / 副流程 1.5s 后仅复位）。
    /// 任意新点击都会 cancel 上一个 task，让两种反馈互斥（用户改主意时不会再触发跳浏览器）。
    @State private var copyResetTask: Task<Void, Never>?

    // 2026-06-29 PAT 折叠区状态
    /// PAT 输入框文本。trim 后空串判定"未输入"。
    @State private var patInput: String = ""
    /// SecureField 明文 / 密文切换。默认 true（密文），点眼睛图标切到明文方便核对 40 字符。
    @State private var patIsSecure: Bool = true
    /// PAT 折叠组展开态。默认 false，idle 态点 chevron 才展开。
    @State private var isPATExpanded: Bool = false
    /// 2026-06-29：「或选择其他登录方式」整体折叠组。默认 false，减少视觉噪音。
    @State private var isAlternativeExpanded: Bool = false

    // 2026-06-29 Device Flow spinner 条件显示
    /// 2026-06-29 dong4j 反馈："等待浏览器完成授权..." 在用户点 code 按钮前就显示，
    /// 但浏览器没打开时"等浏览器"是空话。改为只有用户点 code 按钮（`copyAndOpenBrowser`
    /// 触发了打开浏览器）后才置 true。重新进入 awaitingCode / cancel / 重新 signIn 时重置。
    @State private var hasOpenedBrowser: Bool = false

    /// 卡片宽度。参考图比例约 380pt 宽；macOS sheet 留外圈 padding 后给到 460pt 视觉舒适。
    private let cardWidth: CGFloat = 460
    /// hero 区高度。4 角圆角"独立插画卡"后做 horizontal 16pt 内缩，
    /// 可视宽度 ~428pt，保持 ~2.14:1 的宽屏视觉比例 → 高度 200pt 最协调。
    private let heroHeight: CGFloat = 200
    /// hero 内缩 padding：四周留出卡片底色，让 hero 看起来是浮在卡片里的独立插画卡。
    private let heroInset: CGFloat = 16
    /// sheet 外圈空白（card 到 sheet 边界的距离）。dong4j 2026-06-03 10:38 收紧：32 → 20。
    /// 同时控制 sheet minWidth 和上下 Spacer，保持四周对称留白。
    private let sheetOuterPadding: CGFloat = 20
    /// 关闭按钮相对 card 右上角的"外溢"距离（按钮中心比 card 右上角偏外 N pt，悬浮观感）。
    /// dong4j 设计：8pt 让按钮明显悬浮在 card 外角但又不显得游离。
    /// 必须 ≤ sheetOuterPadding，否则按钮会跑出 sheet 边界。
    private let closeButtonOffset: CGFloat = 8

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: sheetOuterPadding)
                card.frame(width: cardWidth)
                // 上下 sheetOuterPadding 对称留白。
                // 用固定 Spacer 而非 Spacer(minLength:) 让 sheet 高度按 card 高度自适应——
                // idle 态 sheet ~440pt / awaitingCode 态 sheet ~540pt，
                // 状态切换时 sheet 整体高度平滑增减，不会有大块底部空白。
                Spacer().frame(height: sheetOuterPadding)
            }
        }
        // ⚠️ 只锁 minWidth，不锁 minHeight：让 sheet 高度跟 card 实际高度走，
        // 避免历史遗留的固定 minHeight 在 card 高度变化后造成大块底部留白。
        .frame(minWidth: cardWidth + sheetOuterPadding * 2)
        // 关闭按钮:`sheetOuterPadding - closeButtonOffset` = 按钮距 sheet 边距，
        // 必须 ≥ 0 才不会溢出 sheet 边界（否则会被裁切）。
        // 当前 sheetOuterPadding=20, closeButtonOffset=8 → 按钮距 sheet 边 12pt，安全。
        .overlay(alignment: .topTrailing) {
            closeButton.padding(sheetOuterPadding - closeButtonOffset)
        }
    }

    // MARK: - Card

    /// 卡片整体：白底 / 圆角 18 / 轻微阴影。
    /// `.animation(.smooth, value:)` 让状态切换有平滑 fade / size 过渡。
    private var card: some View {
        VStack(spacing: 0) {
            heroSection
            contentSection
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: derivedState)
    }

    // MARK: - Hero

    /// hero 视觉区：5 张图片自动轮播 + 平滑淡入淡出（dong4j 2026-06-03 09:55 需求）。
    /// 4 角圆角（cornerRadius: 14，比卡片外圈的 18 小一档，符合"外大内小"嵌套层级），
    /// 四周用 `heroInset` 留白让 hero 作为独立"插画卡"浮在卡片里。
    ///
    /// 轮播细节（每次打开随机起始 + 5s 间隔 + 1.2s 淡入淡出 + sheet 关时 timer 自动清理）
    /// 见 `AuthHeroCarouselView.swift`。
    private var heroSection: some View {
        AuthHeroCarouselView()
            .frame(height: heroHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, heroInset)
            .padding(.top, heroInset)
    }

    // MARK: - Content

    /// 卡片下半部分：标题 / 副标题 / 状态分支区。
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("authV2.welcome")
                    .font(.title2).fontWeight(.semibold)

                Text("authV2.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            stateSection

            // 2026-06-29：idle / error 态下显示「其他登录方式」折叠区。
            // connecting / awaitingCode / authenticated 态不显示——避免和 Device Flow UI 抢焦点。
            if case .idle = derivedState {
                alternativeSection
            } else if case .error = derivedState {
                alternativeSection
            }

            if case .error = derivedState {
                errorBanner
            }
        }
        .padding(.horizontal, 28)
        // hero 自带 16pt 上 padding，content 顶部 20pt → hero 底到正文顶距离 20pt（视觉协调）
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 按 derivedState 切换：CTA / 连接中 / 等待授权 / 已登录 / 错误占位。
    @ViewBuilder
    private var stateSection: some View {
        switch derivedState {
        case .idle, .error:
            continueWithGitHubButton
        case .connecting:
            connectingView
        case .awaitingCode(let info):
            awaitingUserCodeView(info: info)
        case .awaitingWebCallback(let info):
            awaitingWebCallbackView(info: info)
        case .authenticated:
            authenticatedView
        }
    }

    // MARK: - 状态视图

    // MARK: - 其他登录方式（2026-06-29 新增）

    /// "其他登录方式"折叠区。
    ///
    /// 包含两个子折叠项：
    /// - **PAT 直接输入**：展开后是 SecureField + 提交按钮（可立即登录）
    /// - **Web Application Flow**：W6 之前的占位，disabled + 「即将推出」徽章
    ///
    /// 设计要点：
    /// 2026-06-29：「或选择其他登录方式」折叠组（默认折叠）。
    ///
    /// dong4j 要求**不要** DisclosureGroup 的 `>` chevron，改为纯 Button 点击整行
    /// 展开/折叠——与 PAT 折叠项同款 `withAnimation(.easeInOut(0.18))`。
    /// 默认折叠减少视觉噪音，用户需要非 Device Flow 登录时才展开。
    private var alternativeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 可点击整行（分隔线 + "或选择其他方式" 文案）
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isAlternativeExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                    Text("authV2.alternative.divider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text("authV2.alternative.divider"))

            // 展开后才显示 PAT 折叠项 + Web Flow 入口
            if isAlternativeExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    patDisclosure
                    webFlowRow
                }
                .padding(.top, 4)
            }
        }
    }

    /// PAT 折叠项：点击 chevron 展开 SecureField + 提交按钮。
    ///
    /// 关键约束：
    /// - 输入框 trim 后空串 → 提交按钮 disabled
    /// - `authSession.isAuthenticating == true` → 输入框 + 提交按钮全 disabled
    ///   （防止用户在 PAT 流程进行中又去点 Device Flow / Web Flow / 重复提交 PAT）
    /// - 提交调 `authSession.signInWithPAT(_:)`，UI 不需要手动切 state；
    ///   AuthSession 成功 → state == .authenticated → ContentView 自动 dismiss sheet
    /// - 失败时 lastError 会写入，errorBanner 自动渲染
    /// - macOS 上 SecureField 不能眼睛切换明文，所以用 TextField + `isSecure` 自渲染
    ///   切换按钮（参考 AISettingsView 的 AI Key 输入同款）
    /// - 显隐切换按钮遵守项目强制规范：`.buttonStyle(.plain) + .focusEffectDisabled()`
    private var patDisclosure: some View {
        DisclosureGroup(isExpanded: $isPATExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                // 输入框 + 明文切换眼睛
                HStack(spacing: 6) {
                    Group {
                        if patIsSecure {
                            SecureField("", text: $patInput, prompt: Text("authV2.pat.placeholder"))
                        } else {
                            TextField("", text: $patInput, prompt: Text("authV2.pat.placeholder"))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(authSession.isAuthenticating)
                    .onSubmit(triggerPATSignIn)

                    Button {
                        patIsSecure.toggle()
                    } label: {
                        Image(systemName: patIsSecure ? "eye" : "eye.slash")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .foregroundStyle(.secondary)
                    .help(patIsSecure ? "authV2.pat.showToken" : "authV2.pat.hideToken")
                    .disabled(authSession.isAuthenticating)
                    .accessibilityLabel(patIsSecure ? Text("authV2.pat.showToken") : Text("authV2.pat.hideToken"))
                }

                // 提交按钮（次按钮样式，与主 CTA 区分开）
                Button(action: triggerPATSignIn) {
                    Text("authV2.pat.submit")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(authSession.isAuthenticating || patInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // 帮助文案 + 获取 Token 外链
                Text("authV2.pat.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if let url = URL(string: "https://github.com/settings/tokens") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                        Text("authV2.pat.getToken")
                            .font(.caption)
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("authV2.pat.getToken.help"))
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            // 整行包成 Button：用户点 icon / 文字 / chevron 任意位置都能展开/折叠。
            // SwiftUI `DisclosureGroup` 默认只响应 chevron 区点击，label 内显式 Button
            // 会捕获点击事件并按 `isPATExpanded.toggle()` 切换——比引导用户"找 chevron"
            // 更直接，符合 macOS 用户对"整行可点折叠组"的预期。
            //
            // 项目强制规范：`.buttonStyle(.plain) + .focusEffectDisabled()` 防蓝框 focus ring。
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isPATExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Text("authV2.alternative.pat")
                        .font(.subheadline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text("authV2.alternative.pat"))
        }
    }

    /// 2026-06-29 Web Application Flow（PKCE）入口。
    ///
    /// 行为：整行点击触发 `authSession.signInWithWebFlow()`，弹浏览器走 OAuth Web Flow。
    /// - 已登录：被 `signInWithWebFlow` 内部 `isAuthenticating` 守门忽略（这里也加 disabled 防视觉误操作）
    /// - 已经在走 Web Flow：同样 disabled
    /// - 已经在走 Device Flow：同样 disabled（一次只允许一个登录流程）
    ///
    /// 视觉与 PAT 折叠项的 label 风格一致（icon + 文字 + Spacer + trailing hint）。
    /// 遵守项目强制规范：`.buttonStyle(.plain) + .focusEffectDisabled()`。
    private var webFlowRow: some View {
        Button {
            authSession.signInWithWebFlow()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Text("authV2.alternative.webflow")
                    .font(.subheadline)
                Spacer()
                Text("authV2.alternative.webflow.enabled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(authSession.isAuthenticating)
        .help(Text("authV2.alternative.webflow.tooltip"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("authV2.alternative.webflow"))
    }

    /// idle / error 态：全宽蓝色主按钮。
    private var continueWithGitHubButton: some View {
        bigButton(style: .primary, action: triggerContinue) {
            Text("authV2.continueWithGitHub")
                .fontWeight(.semibold)
        }
    }

    /// connecting 瞬时态：与按钮等高的灰底占位，spinner + 文案。
    /// AuthSession.signIn() 之后到 .awaitingUserCode 之前的过渡（拿 user_code 网络耗时）。
    private var connectingView: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("authV2.connecting")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// awaitingCode 态：两个全宽按钮 + 一行底部 spinner 提示。
    /// - 第 1 行：暖色渐变 code 卡片（全宽，左主区点击 = 复制 + 1.5s 后自动开浏览器；右独立图标 = 仅复制）
    /// - 第 2 行：[ Cancel ] 全宽
    /// - 第 3 行：spinner + "等待浏览器完成授权..." 提示
    ///
    /// 设计取舍（dong4j 2026-06-03 09:07 反馈）：
    /// - 删除右侧引导文字（之前的"点击复制并自动打开 GitHub" / "正在为你打开 GitHub…" / "代码已复制到剪贴板"）：
    ///   主流程已经有 code 主区 ZStack 切到 "已复制 ✓" 的反馈 + 底部 spinner + "等待授权" 提示，
    ///   右侧 hint 属于第 4 处同义提示，删掉减少视觉噪音
    /// - code 卡片改全宽（与 cancel 按钮齐平），不再固定 248pt + 右侧 flex hint 双列布局
    /// 2026-06-29 Web Application Flow / PKCE 等待回调视图。
    ///
    /// 与 `awaitingUserCodeView`（Device Flow）布局完全一致：
    /// - 顶部 hero 图片轮播
    /// - 进度指示（spinner + "等待完成 GitHub 授权..."）
    /// - Cancel 按钮
    ///
    /// 唯一区别：没有 user_code 卡片（Web Flow 不需要用户手动输 code，浏览器自动跳回）。
    /// 关键约束：state 是 .awaitingWebCallback 时 sheet 切到该视图；用户点 Cancel → triggerWebFlowCancel
    /// 调 AuthSession.cancelWebFlow()（暂未实现，先 TODO）。
    private func awaitingWebCallbackView(info: WebFlowStartInfo) -> some View {
        VStack(spacing: 24) {
            // 2026-06-29：与 awaitingUserCodeView（Device Flow）布局完全对称——
            //   - cancelButton（Cancel 调 cancelWebFlow 取消 Web Flow）
            //   - spinner + "等待完成 GitHub 授权..."
            //
            // 唯一区别：没有 codeButton（Web Flow 不需要用户手动输 code，浏览器自动跳回
            // starcat://callback 触发 .onOpenURL）。
            // hero 图片轮播在 card 顶部由 contentSection 共享，所有态都展示，不在这里重复画。
            VStack(spacing: 10) {
                cancelWebFlowButton
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("authV2.webflow.waitingHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Web Flow 专用的 Cancel 按钮：调 AuthSession.cancelWebFlow()
    ///（区别于 Device Flow 的 cancelButton 调 cancelSignIn）
    private var cancelWebFlowButton: some View {
        bigButton(style: .secondary, action: triggerWebFlowCancel) {
            Text("authV2.cancelSignIn")
                .fontWeight(.medium)
        }
    }

    private func awaitingUserCodeView(info: OAuthDeviceCodeInfo) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                codeButton(info: info)
                cancelButton
            }

            // 2026-06-29 改造：底部 spinner + "等待浏览器完成授权..." 改为条件显示，
            // 只有用户在 code 按钮上点了"复制并打开浏览器"（hasOpenedBrowser = true）才显示。
            // 进入 awaitingCode 态但还没点 code 按钮时，浏览器没打开，"等浏览器"是空话。
            if hasOpenedBrowser {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("authV2.waitingHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // 兜底：state 重新进入 .awaitingUserCode（用户重新 signIn 或 cancel 后重试）→ 重置
        // hasOpenedBrowser，让 spinner 重新按"用户点 code 按钮后"才显示的语义生效。
        .onChange(of: authSession.state) { _, newState in
            if case .awaitingUserCode = newState {
                hasOpenedBrowser = false
            }
        }
    }

    /// awaitingCode 第一行左侧：暖色渐变 code 卡片（复合按钮）。
    ///
    /// **两个独立 hit target，共用同一张渐变背景**：
    /// - 左主区（大块）：点击 → 复制 + 1.5s 后**自动开浏览器**（`copyAndOpenBrowser`）
    /// - 右独立图标（`doc.on.doc`）：点击 → **复制 + "✓ 已复制" 反馈但不开浏览器**（`copyCodeOnly`）
    /// - 中间一根半透明白色 1pt 分隔条勾出两 hit target 边界
    ///
    /// **布局关键（dong4j 2026-06-03 10:29 反馈)**：
    /// code/hint 文字必须居中在**整张卡片宽度**（不是左主区宽度），才能跟下方 Cancel 按钮文字
    /// 上下垂直对齐——如果包在左主 Button label 里居中，右侧 41pt 图标占位会让视觉中心偏左 ~20pt。
    /// 解决方案：
    /// - 左主 Button label 改成透明 `Color.clear`，只承担 hit area（不放视觉内容）
    /// - 视觉内容（code / hint / ✓ 已复制）抽到 codeButton 最外层 `.overlay(alignment: .center)`，
    ///   自然居中在 HStack(= 整张卡片)正中
    /// - overlay 内容加 `.allowsHitTesting(false)`，点击事件穿透到下面的两个 Button
    ///
    /// **两个流程都切换 code 主区域显示**（dong4j 2026-06-12 反馈）：
    /// 之前 v2（2026-06-03）副流程下整张卡片不变,理由是怕「主区域文字 + 图标 + hint 文字」3 处同义反馈
    /// 视觉重复;但实际使用中用户点了右侧图标看不到"复制成功"反馈会怀疑是否点中,反而困惑。
    /// 现在两个 hit target 共用 `isCopied` 视觉态(主流程 `.copiedAndOpening` / 副流程 `.copiedSilent`),
    /// 用户操作有清晰反馈,代价是同一时刻确实有 2 处反馈源(✓ 已复制 + macOS Button 默认按下高亮),
    /// 但「2 处反馈」的认知成本远小于「无反馈疑惑」,trade-off 倾向后者。
    private func codeButton(info: OAuthDeviceCodeInfo) -> some View {
        HStack(spacing: 0) {
            // 主区域：透明 hit area，撑满左侧除分隔条 + 图标外的全部空间
            Button {
                copyAndOpenBrowser(info: info)
            } label: {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            // 视觉分隔条：半透明白色 1pt × 30pt。
            // ⚠️ 必须显式给 height！Rectangle 是无限形状，只设 width 会让 HStack
            // 跟着撑成无限高（实测会把 code 卡片拉成 280pt 的方块挤掉 hero）。
            Rectangle()
                .fill(Color.white.opacity(0.45))
                .frame(width: 1, height: 30)

            // 独立复制图标按钮：只复制不开浏览器
            // 图标**固定显示 doc.on.doc，不切到 ✓**：避免按钮自身做切换造成视觉跳动。
            Button {
                copyCodeOnly(info: info)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 40)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("authV2.copyOnly")
        }
        // 固定高度 56pt = code(~18) + spacing(2) + hint(~12) + 上下 padding ~24 的视觉等效。
        // 用固定 height 而非 minHeight 是因为：overlay 视觉内容（高度由其内部决定）跟 HStack
        // hit area 解耦，HStack 必须自己确定高度，否则 Color.clear hit area 会塌缩为 0×0。
        .frame(height: 56)
        // 视觉层：浮在整张 HStack（= 整张卡片）正中。
        // ⚠️ `.allowsHitTesting(false)`：让点击事件穿透到下面的 Button，
        //    否则 overlay 会拦截所有 click 导致主 Button / 图标 Button 都点不到。
        .overlay(alignment: .center) {
            ZStack {
                // 默认态：code 数字（主）+ "点击打开授权页面"提示（辅）
                // ⚠️ hint 仅 UI 展示,不会被复制——`copyToClipboard` 只收 `info.userCode` String 参数,
                //    跟 SwiftUI Text label 完全解耦,加多少行 hint 都不影响剪贴板内容。
                VStack(spacing: 2) {
                    Text(info.userCode)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)

                    Text("authV2.codeHint")
                        .font(.caption2)
                        .opacity(0.65)
                }
                .opacity(copyFeedback.isCopied ? 0 : 1)

                HStack(spacing: 6) {
                    // 用 palette 双色渲染把 checkmark.circle.fill 拆成"深绿圆 + 白勾"双图层,
                    // 比纯线条 ✓ 更接近"成功徽章"的常见视觉语义,在暖橙背景上识别度也更高。
                    // ⚠️ palette 模式下 foregroundStyle 的两个参数顺序是「图层 0 = ✓ / 图层 1 = 圆」,
                    //    不是按颜色字面顺序。给反了会得到深绿勾 + 白色圆(在白色 sheet 上肉眼几乎不可见)。
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color(red: 0.12, green: 0.42, blue: 0.18))
                        .font(.title3)
                    // 文案根据流程区分(dong4j 2026-06-12 反馈):
                    //   主流程 .copiedAndOpening → "已复制,正在打开 GitHub"(暗示 1.5s 后会跳浏览器)
                    //   副流程 .copiedSilent      → "已复制"             (用户已知不会跳浏览器)
                    // .idle 时整个 HStack 已被 opacity(0) 隐藏,这里 fallback 给 .codeCopied 即可。
                    Text(copyFeedback == .copiedAndOpening ? "authV2.codeCopiedAndOpening" : "authV2.codeCopied")
                }
                .font(.subheadline)
                .fontWeight(.semibold)
                // 深森林绿:文字色保持与徽章圆色一致,形成"圆 + 文字"同色系成功反馈;
                // 外层 foregroundStyle 不会覆盖 Image 上已显式声明的 palette 颜色。
                .foregroundStyle(Color(red: 0.12, green: 0.42, blue: 0.18))
                .opacity(copyFeedback.isCopied ? 1 : 0)
            }
            .allowsHitTesting(false)
        }
        .foregroundStyle(BigButtonStyle.codeWarm.foreground)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BigButtonStyle.codeWarm.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(BigButtonStyle.codeWarm.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // 全宽：跟下方 cancel 按钮齐平，视觉上下对齐
    }

    /// awaitingCode 第二行：Cancel 按钮（独占一行全宽）。
    private var cancelButton: some View {
        bigButton(style: .secondary, action: triggerCancel) {
            Text("general.cancel")
        }
    }

    /// authenticated 态：绿色 ✅ + 文案 0.6s 后 dismiss sheet。
    /// 比"瞬间消失"的旧版更友好，让用户清晰感知"我刚才登录成功了"。
    private var authenticatedView: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.title3)
            Text("authV2.signedIn")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.10))
        )
        .task {
            // 0.6s 让用户看清"登录成功"状态再 dismiss
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        }
    }

    /// error 态附加：CTA 下方红色 banner，复用 `auth.failed` 兜底文案。
    @ViewBuilder
    private var errorBanner: some View {
        if let error = authSession.lastError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                errorBannerText(error: error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.08))
            )
        }
    }

    @ViewBuilder
    private func errorBannerText(error: any LocalizedError) -> some View {
        if let description = error.errorDescription {
            Text(verbatim: description)
        } else {
            Text("auth.failed")
        }
    }

    // MARK: - 右上角关闭按钮

    private var closeButton: some View {
        SheetCloseButton(
            action: {
                copyResetTask?.cancel()
                authSession.cancelSignIn()
                dismiss()
            },
            iconFont: .system(size: 20, weight: .medium),
            frameSize: 28
        )
    }

    // MARK: - 统一按钮 helper

    /// 卡片内所有大按钮（主 / 次 / 三态）共用的样式。
    /// 锁定高度（14pt 垂直 padding）+ 圆角 8 + 等宽伸展，确保水平并排时尺寸完全一致。
    @ViewBuilder
    private func bigButton<Label: View>(
        style: BigButtonStyle,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(style.foreground)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(style.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(style.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - 状态派生

    /// 从 AuthSession.state + isAuthenticating + lastError 派生 5 个 UI 态。
    /// 把"3 个互相关联的源"映射到"1 个 UI enum"，让 stateSection 的 switch 写起来干净。
    private var derivedState: DerivedState {
        switch authSession.state {
        case .unauthenticated:
            if authSession.isAuthenticating {
                return .connecting
            } else if authSession.lastError != nil {
                return .error
            } else {
                return .idle
            }
        case .awaitingUserCode(let info):
            return .awaitingCode(info)
        case .awaitingWebCallback(let info):
            return .awaitingWebCallback(info)
        case .authenticated:
            return .authenticated
        }
    }

    // MARK: - 交互

    /// 点 Continue：调 AuthSession 发起 Device Flow。
    /// state 切换到 .awaitingUserCode 由 AuthSession 异步推送，UI 自动重渲染。
    private func triggerContinue() {
        authSession.signIn()
    }

    /// 2026-06-29：点 PAT 提交按钮 / 输入框按回车 → 调 AuthSession.signInWithPAT。
    ///
    /// 守门：
    /// - 输入框 trim 后空串 → 直接 return（按钮已 disabled，这里再兜一次防键盘回车）
    /// - 已经有登录流程在进行（isAuthenticating）→ 直接 return
    ///
    /// 成功后 AuthSession.state 切到 .authenticated，由 ContentView 监听自动 dismiss sheet。
    /// 失败时 AuthSession.lastError 被设置，本视图 `errorBanner` 自动渲染错误。
    private func triggerPATSignIn() {
        let trimmed = patInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !authSession.isAuthenticating else { return }
        Task { await authSession.signInWithPAT(trimmed) }
    }

    /// 点 Cancel：取消进行中的 Device Flow + 复位本地 copy 反馈状态。
    /// AuthSession.cancelSignIn() 把 state 切回 .unauthenticated，
    /// ContentView 检测 isAuthenticating = false 后 sheet 自动 dismiss。
    private func triggerCancel() {
        copyResetTask?.cancel()
        copyFeedback = .idle
        // 2026-06-29：取消时同步重置 hasOpenedBrowser，避免下次重新 signIn 时残留 true
        hasOpenedBrowser = false
        authSession.cancelSignIn()
    }

    /// 2026-06-29：Web Flow Cancel 按钮 action——调 AuthSession.cancelWebFlow()。
    /// 区别于 Device Flow 的 triggerCancel：Web Flow 调 cancelWebFlow 走专门路径
    ///（actor 内部 resetWebFlow 清 verifier/state），Device Flow 调 cancelSignIn 走轮询
    /// 取消路径。两条路线的 actor reset 不同，必须分开调用。
    private func triggerWebFlowCancel() {
        authSession.cancelWebFlow()
    }

    /// 点 code 主区域：一键登录流程
    /// 1. 立即复制 user_code 到剪贴板，code 按钮切到 "已复制 ✓"，hint 切到 "正在为你打开 GitHub…"
    /// 2. 1.5s 后自动 `NSWorkspace.shared.open(info.verificationURI)` 打开 GitHub 设备登录页
    /// 3. 复位到 idle 态，按钮 / 提示文字回到等待下次点击
    private func copyAndOpenBrowser(info: OAuthDeviceCodeInfo) {
        copyToClipboard(info.userCode)
        copyResetTask?.cancel()
        copyFeedback = .copiedAndOpening
        // 2026-06-29：标记"已触发开浏览器流程"——1.5s 后会真打开浏览器，
        // 之后 Device Flow 后台轮询继续等用户在浏览器里授权。
        // spinner 条件 `if hasOpenedBrowser` 在这里打开后一直显示，
        // 直到 state 切到 .authenticated（成功）或 .unauthenticated（失败）。
        hasOpenedBrowser = true
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            NSWorkspace.shared.open(info.verificationURI)
            // 复制反馈的"✓ 已复制"1.5s 后消失，但 hasOpenedBrowser 保持 true，
            // 让底部 spinner 继续显示直到 Device Flow 走完。
            copyFeedback = .idle
        }
    }

    /// 点 code 右侧独立复制图标：仅复制，**给 1.5s 的 "✓ 已复制" 反馈但不开浏览器**。
    ///
    /// 关键副作用：取消上一个倒计时 task（无论是主流程还是副流程的）。
    /// 用户场景：
    /// - 用户先点 code 主区进入 1.5s 倒计时（即将开浏览器）→ 中途改主意点右侧图标只复制 →
    ///   `copyResetTask?.cancel()` 阻止"开浏览器"被触发,改走副流程倒计时（1.5s 后回 idle 不开浏览器）。
    /// - 用户连续点击右侧图标 → 每次都重置倒计时,持续保持 "✓ 已复制" 视觉。
    ///
    /// 反馈策略（dong4j 2026-06-12 修订;v2 2026-06-03 时是"无反馈"，使用中证明会让用户怀疑没点中,
    /// 现在统一与主流程一致地切到 "✓ 已复制",仅在 1.5s 到时不调用 `NSWorkspace.open` 区分语义）。
    private func copyCodeOnly(info: OAuthDeviceCodeInfo) {
        copyToClipboard(info.userCode)
        copyResetTask?.cancel()
        copyFeedback = .copiedSilent
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Task.isCancelled 的 guard 与主流程一致:用户在 1.5s 内再点别处时,
            // 旧 task 即使已经过 sleep 也不应再修改 copyFeedback,避免覆盖新流程的状态。
            guard !Task.isCancelled else { return }
            copyFeedback = .idle
        }
    }

    /// 复制 user_code 到系统剪贴板（两种复制场景共用）。
    private func copyToClipboard(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

// MARK: - Button Style

/// `bigButton(...)` 的四种 visual。
private enum BigButtonStyle {
    case primary    // 蓝色实心，主操作（Continue with GitHub）
    case secondary  // 灰色弱化，次操作（Cancel）
    case tertiary   // 白底带边框，通用三态（暂未使用）
    case codeWarm   // 暖色渐变（日落桃黄 → 暖橙），专用于 awaitingCode 态的 user_code 按钮

    var background: AnyShapeStyle {
        switch self {
        case .primary:
            AnyShapeStyle(Color.accentColor)
        case .secondary:
            AnyShapeStyle(Color.secondary.opacity(0.18))
        case .tertiary:
            AnyShapeStyle(Color(nsColor: .textBackgroundColor))
        case .codeWarm:
            // 日落桃黄 → 暖橙渐变：把 user_code 这个"关键信息"做成全卡片最暖最亮的视觉焦点，
            // 区别于卡片其他冷色（蓝色 hero / 蓝色 primary 按钮 / 灰色 secondary），
            // 引导用户注意力直奔"点这里 → 完成登录"。
            AnyShapeStyle(LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.82, blue: 0.52),   // 桃黄
                    Color(red: 0.99, green: 0.62, blue: 0.36)    // 暖橙
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }

    var foreground: AnyShapeStyle {
        switch self {
        case .primary:
            AnyShapeStyle(Color.white)
        case .secondary, .tertiary:
            AnyShapeStyle(Color.primary)
        case .codeWarm:
            // 深棕色文字在暖色渐变上对比度足够（≥ WCAG AA），保留 user_code 的可读性。
            AnyShapeStyle(Color(red: 0.38, green: 0.16, blue: 0.04))
        }
    }

    var border: AnyShapeStyle {
        switch self {
        case .primary:
            AnyShapeStyle(Color.clear)
        case .secondary:
            AnyShapeStyle(Color.clear)
        case .tertiary:
            AnyShapeStyle(Color.primary.opacity(0.12))
        case .codeWarm:
            // 极浅的描边，把按钮在暗色背景下勾出清晰边界（无描边在暗色 sheet 上会模糊融化）。
            AnyShapeStyle(Color(red: 0.85, green: 0.50, blue: 0.20).opacity(0.35))
        }
    }
}

// MARK: - Copy Feedback

/// awaitingCode 态 code 卡片的复制反馈状态机（三态）。
/// - `.idle`：code 主区域显示 user_code 数字
/// - `.copiedAndOpening`：主流程触发 → code 主区切到 "已复制 ✓" + 1.5s 后自动开浏览器
/// - `.copiedSilent`：副流程触发(点右侧图标) → code 主区切到 "已复制 ✓" + 1.5s 后仅复位
///
/// 两个 "copied" 态视觉完全相同(都让 `isCopied == true`),区别仅在副作用:
/// `.copiedAndOpening` 倒计时结束后调用 `NSWorkspace.open(verificationURI)`,
/// `.copiedSilent` 倒计时结束后只复位回 `.idle` 不开浏览器。
///
/// 演化轨迹:
/// - v1（2026-06-03 09:07）：副流程无 UI 反馈,枚举里只有 `.idle / .copiedAndOpening` 两态;
///   理由是怕「主区域文字 + 图标 + hint 文字」3 处同义反馈视觉重复。
/// - v2（2026-06-12,dong4j 反馈）：使用中发现副流程无反馈让用户怀疑是否点中,
///   恢复 `.copiedSilent` 态让两流程都给清晰反馈。
private enum CopyFeedback: Equatable {
    case idle
    case copiedAndOpening
    case copiedSilent

    /// 是否需要把 code 主区域文字切到 "✓ 已复制"。两个 "copied" 态都返回 true。
    var isCopied: Bool {
        switch self {
        case .idle: return false
        case .copiedAndOpening, .copiedSilent: return true
        }
    }
}

// MARK: - Derived State

/// AuthSession 三个源（state / isAuthenticating / lastError）派生的 5 个 UI 态。
/// 让 `stateSection` 的 switch 写起来干净 + `animation(value:)` 有干净的依赖源。
private enum DerivedState: Equatable {
    case idle
    case connecting
    case awaitingCode(OAuthDeviceCodeInfo)
    /// 2026-06-29 新增：专用于 Web Application Flow（PKCE），与 `.awaitingCode` 同款
    /// "等用户授权"语义，但实现是浏览器回调而不是输 code。
    case awaitingWebCallback(WebFlowStartInfo)
    case authenticated
    case error
}
