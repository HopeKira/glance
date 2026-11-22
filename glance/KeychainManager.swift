//
//  KeychainManager.swift
//  glance
//
//  Thin, password-agnostic wrapper around Keychain Services — save/read/delete/exists by account, plus a Touch-ID access control helper.
//

import Foundation
import Security
import LocalAuthentication
import CryptoKit

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case accessControlFailed(String)
    case authenticationFailed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "未找到钥匙串项目。"
        case .unexpectedData:
            return "钥匙串项目格式异常。"
        case .accessControlFailed(let msg):
            return "Couldn't create Keychain access control: \(msg)"
        case .authenticationFailed:
            return "验证被取消或失败。"
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

enum KeychainManager {
    nonisolated static let service = "com.imanity.glance.v2"

    /// Attributes-only existence check — never prompts, even for access-controlled items.
    nonisolated static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecItemNotFound
    }

    /// Pass an `LAContext` to authorize a read on an access-controlled item — the OS presents the prompt during this call.
    nonisolated static func read(account: String, context: LAContext? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        // 会话密钥若已降级为普通项，带 LAContext 读取时重试一次不带 context。
        if status != errSecSuccess, context != nil {
            var plain = query
            plain.removeValue(forKey: kSecUseAuthenticationContext as String)
            item = nil
            status = SecItemCopyMatching(plain as CFDictionary, &item)
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Stores an item, updating its data in place when it already exists. Updating
    /// avoids the delete/add gap that can race with a second submit and produce
    /// `errSecDuplicateItem`. Existing access-control attributes are preserved;
    /// this method's access-control argument applies when adding a new item.
    nonisolated static func save(account: String, data: Data,
                                accessControl: SecAccessControl? = nil,
                                useSelfAccessOnly: Bool = false) throws {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break // Add below.
        default:
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        if let accessControl {
            addQuery[kSecAttrAccessControl as String] = accessControl
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        // 把「只有本 app 可读」预先写进 file-keychain ACL，钥匙串确认框就不会出现在
        // 无法应答的锁屏界面。kSecAttrAccess 与 kSecAttrAccessible 互斥，不能同时给。
        if useSelfAccessOnly, let access = selfAccess() {
            addQuery.removeValue(forKey: kSecAttrAccessible as String)
            addQuery[kSecAttrAccess as String] = access
        }

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecParam, addQuery[kSecAttrAccess as String] != nil {
            addQuery.removeValue(forKey: kSecAttrAccess as String)
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status == errSecSuccess { return }
        // 自签证书没有 Team ID 时，创建带 SecAccessControl(.userPresence) 的项可能
        // 因缺少 entitlement 返回 -34018。降级为普通 Keychain 项：仍受签名身份 ACL
        // 保护，只是不再要求 Touch ID 二次验证 —— 保证引导能继续走完。
        if accessControl != nil, status != errSecDuplicateItem {
            var fallback = addQuery
            fallback.removeValue(forKey: kSecAttrAccessControl as String)
            fallback[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let retry = SecItemAdd(fallback as CFDictionary, nil)
            if retry == errSecSuccess {
                GlanceLog.write("Keychain: ACL 项创建失败(\(status))，已降级为普通项（无 Touch ID 门禁）")
                return
            }
            status = retry
        }
        // Another save may have added the item after our update reported
        // not-found. Complete that competing replacement with an update instead
        // of surfacing an avoidable “item already exists” error.
        if status == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                itemQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else { throw KeychainError.osStatus(retryStatus) }
            return
        }
        throw KeychainError.osStatus(status)
    }

    nonisolated static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// 预置「只有本 app 可读」的 file-keychain ACL。这两个 API 已标 deprecated，
    /// 但沙箱外没有替代实现；去掉它锁屏时就会弹出无法应答的钥匙串确认框。
    nonisolated private static func selfAccess() -> SecAccess? {
        var app: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess,
              let app else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Glance" as CFString, [app] as CFArray, &access)
                == errSecSuccess else { return nil }
        return access
    }

    /// `.userPresence` requires Touch ID or device password, with no separate no-hardware handling needed.
    nonisolated static func makeUserPresenceAccessControl() throws -> SecAccessControl {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            let msg = (accessError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw KeychainError.accessControlFailed(msg)
        }
        return access
    }
}


/// 会话密钥的硬件级封存。思路来自 KINN-CH/FaceUnlock 的 EnclaveCrypto：
/// Secure Enclave 内不可导出的 P-256 私钥做 ECDH + HKDF 派生对称密钥，
/// 钥匙串里只存私钥 blob（只有本机 Enclave 能还原）与被它封存的密文。
/// 不依赖 Team ID / Touch ID ACL，正好适配自签证书。
/// CryptoKit 封存/解封是纯函数、线程安全（每次调用从钥匙串读取 Enclave 密钥），
/// 可由后台钥匙串函数调用；显式 nonisolated 满足 Swift 6。
nonisolated enum SealedKeyCrypto {
    static let magic = Data("GLANCE-SEALED-V1".utf8)

    private static let enclaveKeyAccount = "enclaveKeyBlob"
    private static let fallbackKeyAccount = "fallbackSymmetricKey"

    enum SealedKeyError: LocalizedError {
        case notSealed
        case noKey
        case sealFailed(String)
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSealed: return "会话密钥格式异常。"
            case .noKey: return "无法创建加密密钥（锁屏界面不允许新建）。"
            case .sealFailed(let m): return "封存失败：\(m)"
            case .openFailed(let m): return "解封失败：\(m)"
            }
        }
    }

    static var usesSecureEnclave: Bool { SecureEnclave.isAvailable }

    private static func symmetricKey(allowInteraction: Bool) throws -> SymmetricKey {
        if usesSecureEnclave {
            let key = try enclaveKey(allowInteraction: allowInteraction)
            let shared = try key.sharedSecretFromKeyAgreement(with: key.publicKey)
            return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                  salt: Data("Glance.v1".utf8),
                                                  sharedInfo: Data(),
                                                  outputByteCount: 32)
        }
        return try fallbackKey(allowInteraction: allowInteraction)
    }

    private static func enclaveKey(allowInteraction: Bool) throws
            -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let blob = try? KeychainManager.read(account: enclaveKeyAccount),
           let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob) {
            return key
        }
        // 锁屏界面绝不能新建密钥：一旦新建，旧密文将永久无法解开。
        guard allowInteraction else { throw SealedKeyError.noKey }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        try KeychainManager.save(account: enclaveKeyAccount,
                                 data: key.dataRepresentation,
                                 useSelfAccessOnly: true)
        GlanceLog.write("会话密钥封存：已创建 Secure Enclave 密钥")
        return key
    }

    /// 无 Secure Enclave 的老机器降级路径（保护级别低一档）。
    private static func fallbackKey(allowInteraction: Bool) throws -> SymmetricKey {
        if let data = try? KeychainManager.read(account: fallbackKeyAccount) {
            return SymmetricKey(data: data)
        }
        guard allowInteraction else { throw SealedKeyError.noKey }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try KeychainManager.save(account: fallbackKeyAccount, data: data, useSelfAccessOnly: true)
        GlanceLog.write("会话密钥封存：无 Secure Enclave，降级为钥匙串对称密钥")
        return key
    }

    static func seal(_ plaintext: Data) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: try symmetricKey(allowInteraction: true))
            guard let combined = box.combined else { throw SealedKeyError.sealFailed("no combined") }
            var out = magic
            out.append(combined)
            return out
        } catch let error as SealedKeyError { throw error }
        catch { throw SealedKeyError.sealFailed(error.localizedDescription) }
    }

    static func open(_ blob: Data, allowInteraction: Bool = true) throws -> Data {
        guard blob.starts(with: magic) else { throw SealedKeyError.notSealed }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(blob.dropFirst(magic.count)))
            return try AES.GCM.open(box, using: try symmetricKey(allowInteraction: allowInteraction))
        } catch let error as SealedKeyError { throw error }
        catch { throw SealedKeyError.openFailed(error.localizedDescription) }
    }

    /// 在用户可交互时预先派生一次，把可能出现的钥匙串确认框留在锁屏之前。
    static func warmUp() {
        _ = try? symmetricKey(allowInteraction: true)
    }
}
