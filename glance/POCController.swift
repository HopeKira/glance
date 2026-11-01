//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation
import LocalAuthentication

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
            try await authenticateIfKeychainGateUnavailable()
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "验证身份以设置或使用 Glance")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    /// 本机构建没有 `com.apple.application-identifier`（ad-hoc 签名）时，钥匙串条目无法带 userPresence 访问控制，
    /// 系统不会弹 Touch ID。这里补一次显式的生物识别/密码验证，保证解锁会话仍然需要「人」的确认。
    private func authenticateIfKeychainGateUnavailable() async throws {
        guard !KeychainManager.hasApplicationIdentifierEntitlement else { return }
        guard !SecureCredentialManager.isSessionUnlocked else { return }
        let context = LAContext()
        context.localizedReason = "验证身份以解锁 Glance 会话"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw KeychainError.authenticationFailed
        }
        do {
            _ = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "验证身份以解锁 Glance 会话"
            )
        } catch {
            throw KeychainError.authenticationFailed
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
    func injectStoredPassword(requireAuthoritativeLock: Bool = false) async {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "未获得“辅助功能”权限——请打开“系统设置”并启用 Glance。"
            return
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "会话已锁定——请先用触控 ID 验证。"
            return
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "已跳过：CGSession 报告屏幕并未真正锁定。"
                return
            }
        }

        statusMessage = "正在输入…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
            statusMessage = "Injected stored password + Return at \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
        }
    }
}
