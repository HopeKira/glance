//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "Idle"

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "验证身份以设置或使用 Glance")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "请先输入密码。"
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "密码已保存并加密。"
            hasStoredPassword = true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Reads + decrypts + injects the stored password, zeroing the plaintext
    /// buffer before returning. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked.
    /// 自检：与真实注入走同一套权限/会话/键盘链路，只是把内容换成占位串，
    /// 让用户可以在文本编辑器里安全确认「刷脸 → 自动输入」整条链路是否通。
    @discardableResult
    func injectSelfTestString() async -> Bool {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "未获得“辅助功能”权限——请打开“系统设置”并启用 Glance。"
            GlanceLog.write("自检失败：未获得辅助功能权限")
            return false
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "会话已锁定——请先在菜单栏完成一次验证。"
            GlanceLog.write("自检失败：会话已锁定")
            return false
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try KeystrokeInjector.typeAndReturn(Data("Glance 刷脸输入测试 OK".utf8))
            }.value
            statusMessage = "自检通过：已在当前窗口输入测试文本"
            GlanceLog.write("自检成功：测试文本已输入")
            return true
        } catch {
            statusMessage = "自检失败：\(error.localizedDescription)"
            GlanceLog.write("自检失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func injectStoredPassword(requireAuthoritativeLock: Bool = false) async -> Bool {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "未获得“辅助功能”权限——请打开“系统设置”并启用 Glance。"
            GlanceLog.write("注入失败：未获得辅助功能权限")
            return false
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "会话已锁定——请先用触控 ID 验证。"
            GlanceLog.write("注入失败：会话已锁定")
            return false
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "已跳过：CGSession 报告屏幕并未真正锁定。"
                GlanceLog.write("注入失败：CGSession 报告屏幕未锁定")
                return false
            }
        }

        statusMessage = "正在输入…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
            statusMessage = "已在 \(Date().formatted(date: .omitted, time: .standard)) 输入密码并回车"
            GlanceLog.write("注入成功")
            return true
        } catch {
            statusMessage = "输入失败：\(error.localizedDescription)"
            GlanceLog.write("注入失败：\(error.localizedDescription)")
            return false
        }
    }
}
