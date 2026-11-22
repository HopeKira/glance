//
//  SecureCredentialManager.swift
//  glance
//
//  Two-tier storage on KeychainManager: a Touch-ID-gated session key (unwrapped once per launch) wraps an ungated encrypted
//  password blob, safe to read anytime — including the lock screen, where no app UI exists to host a Touch ID prompt.
//  Touch ID authorizes the session; nothing yet authorizes each individual unlock beyond that (face recognition will).
//

import Foundation
import CryptoKit
import LocalAuthentication

enum SecureCredentialError: LocalizedError {
    case emptyPassword
    case sessionLocked
    case encryptionFailed
    case decryptionFailed
    case sessionKeyUnavailable
    case injectionAborted

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "密码不能为空。"
        case .sessionLocked:
            return "会话已锁定。请先用触控 ID 验证，再保存或使用密码。"
        case .encryptionFailed:
            return "加密失败。"
        case .decryptionFailed:
            return "解密失败。已保存的凭据可能已损坏。"
        case .injectionAborted:
            return "屏幕已解锁，已取消输入密码。"
        case .sessionKeyUnavailable:
            return "会话密钥已丢失，但仍有只能由它解密的加密数据。没有删除任何内容。在“密码”标签页删除已保存的密码即可清除两者并重新开始。"
        }
    }
}

extension Notification.Name {
    /// Fires whenever the cached session key changes, so anything encrypted under it (e.g. `FaceEnrollmentStore`) can reload
    /// itself instead of relying on each call site to remember to — a past bug had the sidebar's unlock forget this, leaving
    /// face unlock silently running on stale pre-unlock data.
    /// immutable 常量，线程安全；显式 nonisolated 供后台钥匙串函数调用。
    nonisolated static let secureCredentialSessionDidChange = Notification.Name("SecureCredentialManager.sessionDidChange")
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"
    nonisolated private static let sealedMagic = SealedKeyCrypto.magic
    nonisolated private static let passwordBlobAccount = "encryptedPassword"

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?
    /// Last unlock or successful `readPassword` — what `SessionAutoLocker` compares against the idle limit. Guarded by
    /// `sessionLock` alongside the key so the two can never be observed out of step.
    nonisolated(unsafe) private static var _lastActivityAt: Date?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    /// `nil` whenever the session is locked — there is no activity to age.
    nonisolated static var lastActivityAt: Date? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _lastActivityAt
    }

    nonisolated private static func cachedKey() -> SymmetricKey? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey
    }

    nonisolated private static func setCachedKey(_ key: SymmetricKey?) {
        sessionLock.lock()
        let changed = (key != nil) != (_cachedKey != nil)
        _cachedKey = key
        _lastActivityAt = key == nil ? nil : Date()
        sessionLock.unlock()
        // Posted after releasing the lock — observers may call back into `isSessionUnlocked` (re-acquiring it) from a
        // background thread, so posting while still locked risks a real self-deadlock, not a theoretical one.
        guard changed else { return }
        NotificationCenter.default.post(name: .secureCredentialSessionDidChange, object: nil)
    }

    /// Resets the idle countdown on each successful use, so an actively-used session never auto-locks.
    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _cachedKey != nil { _lastActivityAt = Date() }
        sessionLock.unlock()
    }

    // MARK: - Generic session-key crypto (shared by passwords here and face embeddings in SecureFaceStore; requires an unlocked session)

    nonisolated static func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw SecureCredentialError.encryptionFailed }
            return combined
        } catch {
            throw SecureCredentialError.encryptionFailed
        }
    }

    nonisolated static func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureCredentialError.decryptionFailed
        }
    }

    // MARK: - Public API

    nonisolated static func hasStoredPassword() -> Bool {
        KeychainManager.exists(account: passwordBlobAccount)
    }

    /// Prompts Touch ID and unwraps the session key, creating it Touch-ID-gated on first run. Caches only after a real gated
    /// read-back succeeds — `SecItemAdd` alone returns success even if the user hit Cancel on the auth UI, and bridging
    /// `LAContext.evaluatePolicy` synchronously via a semaphore deadlocks the thread pool and crashes the process.
    /// Must succeed before `savePassword`/`readPassword`. Blocking; call from a background task.
    nonisolated static func unlockSession(reason: String) throws {
        if cachedKey() != nil { return }

        // The existence check, not the read, decides whether a key gets created (load-bearing): a cancelled Touch ID prompt on
        // a user-presence item reports `errSecItemNotFound`, indistinguishable from no key — deciding on the read's error would
        // mint a fresh key (destroying the one that decrypts existing data) on every mis-tap.
        if KeychainManager.exists(account: sessionKeyAccount) {
            let context = LAContext()
            context.localizedReason = reason
            let stored = try KeychainManager.read(account: sessionKeyAccount, context: context)
            let keyData: Data
            if stored.starts(with: sealedMagic) {
                keyData = try SealedKeyCrypto.open(stored, allowInteraction: true)
            } else {
                // 旧格式（明文 32 字节）：先读成功、再封存写回；写回失败就原样保留，
                // 绝不删改旧值，避免已录数据永久解不开。
                keyData = stored
                do {
                    try KeychainManager.save(account: sessionKeyAccount,
                                             data: try SealedKeyCrypto.seal(stored))
                    GlanceLog.write("会话密钥：已迁移为 Secure Enclave 封存")
                } catch {
                    GlanceLog.write("会话密钥：封存迁移失败，保留原格式（\(error.localizedDescription)）")
                }
            }
            setCachedKey(SymmetricKey(data: keyData))
            SealedKeyCrypto.warmUp()
            return
        }

        // No key at all, but minting one is still destructive if data is already encrypted under a previous key (e.g. a
        // re-signed dev build) — refuse rather than silently render it unreadable forever.
        guard !hasSessionEncryptedData else {
            throw SecureCredentialError.sessionKeyUnavailable
        }

        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        let stored: Data
        do {
            stored = try SealedKeyCrypto.seal(raw)
        } catch {
            GlanceLog.write("会话密钥：封存不可用，降级为普通项（\(error.localizedDescription)）")
            stored = raw
        }
        let access = try? KeychainManager.makeUserPresenceAccessControl()
        try KeychainManager.save(account: sessionKeyAccount, data: stored, accessControl: access)

        // Read back through the gated path rather than trusting the write — only a real read proves authentication happened.
        let readBackContext = LAContext()
        readBackContext.localizedReason = reason
        let readBack = try KeychainManager.read(account: sessionKeyAccount, context: readBackContext)
        let verified: Data = readBack.starts(with: sealedMagic)
            ? (try SealedKeyCrypto.open(readBack, allowInteraction: true))
            : readBack
        setCachedKey(SymmetricKey(data: verified))
        SealedKeyCrypto.warmUp()
    }

    /// v2: 静默解锁——不带 LAContext、不弹任何密码/Touch ID。
    /// 当前自签证书下 sessionKey 是"无门禁普通项"（-34018 降级），可被静默读出；
    /// 本机 Secure Enclave 解封也是纯本地运算，无需交互。
    /// 返回是否成功；若钥匙串项未来恢复真门禁（Apple 签名 + entitlement），静默读会失败，
    /// 届时行为退回用户手动解锁，不影响安全。
    @discardableResult
    nonisolated static func trySilentUnlock() -> Bool {
        guard cachedKey() == nil,
              KeychainManager.exists(account: sessionKeyAccount) else {
            return cachedKey() != nil
        }
        do {
            // 不带 context：普通项直接返回；真门禁项会返回 errSecInteractionNotAllowed 而非弹窗。
            let stored = try KeychainManager.read(account: sessionKeyAccount)
            let keyData = try SealedKeyCrypto.open(stored, allowInteraction: false)
            setCachedKey(SymmetricKey(data: keyData))
            SealedKeyCrypto.warmUp()
            return true
        } catch {
            return false
        }
    }

    /// Checked without needing the key itself, so this stays answerable precisely when the key can't be read.
    nonisolated static var hasSessionEncryptedData: Bool {
        KeychainManager.exists(account: passwordBlobAccount) || SecureFaceStore.exists
    }

    /// Clears the cached session key. Next save/read requires Touch ID again.
    nonisolated static func lockSession() {
        setCachedKey(nil)
    }

    /// Encrypts and stores `passwordBytes`. Requires an unlocked session —
    /// call `unlockSession(reason:)` first. Blocking; call from a background task.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        let combined = try encrypt(passwordBytes)
        try KeychainManager.save(account: passwordBlobAccount, data: combined)
    }

    /// No separate Touch ID prompt — only the session key was gated, at unlock time. Caller MUST zero the returned bytes via
    /// `.resetBytes(in:)` after use. Blocking; call from a background task.
    nonisolated static func readPassword() throws -> Data {
        guard cachedKey() != nil else { throw SecureCredentialError.sessionLocked }
        let ciphertext = try KeychainManager.read(account: passwordBlobAccount)
        let plaintext = try decrypt(ciphertext)
        // Only on success: a failed read shouldn't extend the idle window.
        recordActivity()
        return plaintext
    }

    /// Deletes both Keychain items and clears the cached session key.
    nonisolated static func deletePassword() throws {
        try KeychainManager.delete(account: passwordBlobAccount)
        try KeychainManager.delete(account: sessionKeyAccount)
        setCachedKey(nil)
    }
}
