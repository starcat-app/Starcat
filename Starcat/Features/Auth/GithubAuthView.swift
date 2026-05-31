//
//  GithubAuthView.swift
//  Starcat
//
//  GitHub 登录页（Device Flow）。
//
//  UI 状态：
//  - 未登录态：展示 GitHub 图标 + "使用 GitHub 登录"按钮 + DEBUG 下额外提供"开发模式跳过"按钮
//  - awaitingUserCode：展示 user_code（可复制）+ "打开 GitHub" 按钮 + 取消按钮 + 等待动画
//  - 错误态：lastError 显示在按钮上方
//

import SwiftUI
import AppKit

struct GithubAuthView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            header
            content
            errorBanner
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 360)
        .overlay(alignment: .topTrailing) {
            Button {
                authSession.cancelSignIn()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .padding(20)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Starcat")
                .font(.title)
                .fontWeight(.semibold)
            Text("整理、理解、找回、评估你的 GitHub Stars")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch authSession.state {
        case .unauthenticated:
            unauthenticatedView
        case .awaitingUserCode(let info):
            awaitingUserCodeView(info)
        case .authenticated:
            ProgressView()  // 转场过渡用，理论上 ContentView 已经切到主界面
        }
    }

    private var unauthenticatedView: some View {
        VStack(spacing: 12) {
            Button {
                authSession.signIn()
            } label: {
                Label("使用 GitHub 登录", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: 240)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .focusEffectDisabled()
            .disabled(authSession.isAuthenticating)
        }
    }

    private func awaitingUserCodeView(_ info: OAuthDeviceCodeInfo) -> some View {
        VStack(spacing: 16) {
            Text("请在浏览器中输入以下 code")
                .font(.headline)

            HStack(spacing: 12) {
                Text(info.userCode)
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.userCode, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .focusEffectDisabled()
                .help("复制 code")
            }

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(info.verificationURI)
                } label: {
                    Label("打开 GitHub", systemImage: "safari")
                        .frame(maxWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .focusEffectDisabled()

                Button("取消") {
                    authSession.cancelSignIn()
                    dismiss()
                }
                .controlSize(.large)
                .focusEffectDisabled()
            }

            ProgressView()
                .controlSize(.small)
            Text("等待授权中…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Error

    @ViewBuilder
    private var errorBanner: some View {
        if let error = authSession.lastError {
            Text(error.errorDescription ?? "登录失败")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
                .multilineTextAlignment(.center)
        }
    }
}
