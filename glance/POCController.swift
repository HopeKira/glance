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

    /// 连续「密码已提交但屏幕仍锁定」到阈值后暂停自动注入，避免账户被锁。
    /// 与永久停用不同：熔断是临时的，冷却后自动恢复 —— 误判时用户无需重存密码，
    /// 也不会被锁在自动解锁之外（锁屏界面进不了设置页重存密码）。
    private var consecutiveUnlockFailures = 0
    private let maxConsecutiveUnlockFailures = 2
    /// 熔断后的冷却时长：到期自动恢复自动解锁。
    private let rejectionCooldown: TimeInterval = 5 * 60
    private var cooldownTask: Task<Void, Never>?
    private(set) var passwordRejected = false

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
            cooldownTask?.cancel()
            cooldownTask = nil
            consecutiveUnlockFailures = 0
            passwordRejected = false
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
        guard !passwordRejected else {
            statusMessage = "自动解锁已临时暂停（连续多次未解锁），几分钟后会自动恢复；如需立即恢复，请在“密码”标签页重新保存 Mac 登录密码。"
            return false
        }
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
                // 紧邻注入的第二次锁屏确认：解密取密码期间用户可能已手动解锁。
                if requireAuthoritativeLock {
                    guard LockMonitor.isScreenActuallyLocked() else {
                        throw SecureCredentialError.injectionAborted
                    }
                }
                // 第三道复核放进注入器内部、紧贴清屏与输入之前，堵住"二次确认后
                // 到 CGEvent 投递之间用户手动解锁"的凭据泄露窗口。
                try KeystrokeInjector.typeAndReturn(bytes) {
                    !requireAuthoritativeLock || LockMonitor.isScreenActuallyLocked()
                }
            }.value
            statusMessage = "已在 \(Date().formatted(date: .omitted, time: .standard)) 输入密码并回车"
            GlanceLog.write("注入成功")
        } catch {
            statusMessage = "输入失败：\(error.localizedDescription)"
            GlanceLog.write("注入失败：\(error.localizedDescription)")
            return false
        }

        if requireAuthoritativeLock {
            // 返回实际解锁结果，而不是无条件 true —— 否则 UI 会误播成功动画，
            // 上层也无法据实决定是否触发 autoRetry。
            return await verifyUnlockOutcome()
        }
        return true
    }

    /// 确认解锁结果：系统稍慢不误判成失败、不重复注入；
    /// 连续 2 次「密码已提交但屏幕仍锁定」才熔断，且熔断改为临时冷却后自动恢复。
    /// - Returns: 屏幕是否确实解锁成功。
    private func verifyUnlockOutcome() async -> Bool {
        // 放宽判定窗口：CGSession 状态本身有 ~150ms 以上滞后，慢机器/密码提示延迟
        // 会让解锁超过 2s。窗口太短正是上次「误判 → 熔断 → 用户被锁住」的根因。
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !LockMonitor.isScreenActuallyLocked() {
                consecutiveUnlockFailures = 0
                return true
            }
        }
        consecutiveUnlockFailures += 1
        GlanceLog.write("解锁失败：密码已提交但屏幕仍锁定（连续 \(consecutiveUnlockFailures) 次）")
        if consecutiveUnlockFailures >= maxConsecutiveUnlockFailures {
            passwordRejected = true
            statusMessage = "已临时暂停自动解锁：密码连续未被接受。将在 \(Int(rejectionCooldown / 60)) 分钟后自动恢复；如需立即恢复，请在“密码”标签页重新保存 Mac 登录密码。"
            GlanceLog.write("解锁失败：连续 2 次，暂停自动解锁 \(Int(rejectionCooldown / 60)) 分钟")
            // 临时熔断：冷却后自动恢复，不再要求用户手动重存密码。
            cooldownTask?.cancel()
            let cooldownNS = UInt64(rejectionCooldown * 1_000_000_000)
            cooldownTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: cooldownNS)
                guard let strongSelf = self, !Task.isCancelled else { return }
                strongSelf.consecutiveUnlockFailures = 0
                strongSelf.passwordRejected = false
                strongSelf.statusMessage = "自动解锁已自动恢复。"
                GlanceLog.write("自动解锁：冷却结束，已自动恢复")
            }
        }
        return false
    }
}
