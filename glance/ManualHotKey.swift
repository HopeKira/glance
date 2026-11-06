//
//  ManualHotKey.swift
//  glance
//
//  「刷脸输入密码」的全局快捷键。用 Carbon 的 RegisterEventHotKey 注册——
//  不需要辅助功能之外的额外权限，也不会被 App 自身的键位处理吞掉。
//  快捷键的键码与修饰键存在 GlanceSettings 里，用户在设置页改完即时生效。
//

import AppKit
import Carbon.HIToolbox

final class ManualHotKey {
    static let shared = ManualHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var onTrigger: (() -> Void)?
    private static let signature: OSType = 0x474C4831  // 'GLH1'
    private static let hotKeyID: UInt32 = 1

    private init() {}

    /// 装好回调并注册当前快捷键。
    func configure(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        installHandlerIfNeeded()
        refresh()
    }

    /// 设置改变后重新注册（先注销旧的，避免重复绑定失败）。
    func refresh() {
        unregister()
        let code = GlanceSettings.shared.manualHotKeyCode
        let modifiers = GlanceSettings.shared.manualHotKeyModifiers
        guard code >= 0, modifiers != 0 else { return }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(code),
            UInt32(modifiers),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            GlanceLog.write("快捷键注册失败 status=\(status)")
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    fileprivate func fire() {
        onTrigger?()
    }

    private var hasInstalledHandler = false

    private func installHandlerIfNeeded() {
        guard !hasInstalledHandler else { return }
        hasInstalledHandler = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr, pressedID.signature == ManualHotKey.signature else { return noErr }
                DispatchQueue.main.async { ManualHotKey.shared.fire() }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }
}

/// 把 (keyCode, Carbon 修饰键) 渲染成 ⌃⌥⇧⌘P 这样的可读文本。
enum HotKeyDisplay {
    static func string(keyCode: Int, modifiers: Int) -> String {
        guard modifiers != 0 else { return "未设置" }
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + keyName(for: keyCode)
    }

    static func keyName(for keyCode: Int) -> String {
        if let special = specialKeys[keyCode] { return special }
        if let letter = letters[keyCode] { return letter }
        if let digit = digits[keyCode] { return digit }
        return "键码 \(keyCode)"
    }

    /// Carbon 虚拟键码 → 可读名。只覆盖常用键，其余回退成键码。
    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z"
    ]

    private static let digits: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9"
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "空格", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]
}
