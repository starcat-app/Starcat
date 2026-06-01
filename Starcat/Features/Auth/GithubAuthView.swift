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
            Text("auth.title")
                .font(.title)
                .fontWeight(.semibold)
            Text("auth.subtitle")
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
            // 登录完成，显示短暂过渡动画后自动关闭 sheet
            ProgressView()
                .onAppear {
                    dismiss()
                }
        }
    }

    private var unauthenticatedView: some View {
        VStack(spacing: 12) {
            Button {
                authSession.signIn()
            } label: {
                Label("auth.signIn", systemImage: "person.crop.circle.badge.checkmark")
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
            Text("auth.enterCode")
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
                .help("auth.copyCode")
            }

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(info.verificationURI)
                } label: {
                    Label("auth.openGithub", systemImage: "safari")
                        .frame(maxWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .focusEffectDisabled()

                Button("general.cancel") {
                    authSession.cancelSignIn()
                    dismiss()
                }
                .controlSize(.large)
                .focusEffectDisabled()
            }

            ProgressView()
                .controlSize(.small)
            Text("auth.waiting")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Error

    @ViewBuilder
    private var errorBanner: some View {
        if let error = authSession.lastError {
            errorText(description: error.errorDescription)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func errorText(description: String?) -> some View {
        if let description {
            Text(verbatim: description)
        } else {
            Text("auth.failed")
        }
    }
}
