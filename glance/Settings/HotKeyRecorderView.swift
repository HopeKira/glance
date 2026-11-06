//
//  HotKeyRecorderView.swift
//  glance
//
//  设置页里的「按下组合键」录制控件：一个吃 keyDown 的 NSView，
//  捕获到带修饰键的组合后回调，Esc 取消。
//

import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotKeyRecorderView: NSViewRepresentable {
    /// (keyCode, Carbon 修饰键)。取消时回传 (nil)。
    let onCapture: (Int?, Int?) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onCapture = onCapture
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.onCapture = onCapture
    }
}

final class RecorderNSView: NSView {
    var onCapture: ((Int?, Int?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Esc 取消
        if event.keyCode == UInt16(kVK_Escape) {
            onCapture?(nil, nil)
            return
        }

        var modifiers = 0
        if event.modifierFlags.contains(.control) { modifiers |= controlKey }
        if event.modifierFlags.contains(.option) { modifiers |= optionKey }
        if event.modifierFlags.contains(.shift) { modifiers |= shiftKey }
        if event.modifierFlags.contains(.command) { modifiers |= cmdKey }

        // 只按修饰键不放字母/功能键时，给个提示音继续等
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }
        onCapture?(Int(event.keyCode), modifiers)
    }

    override func flagsChanged(with event: NSEvent) {
        // 忽略单独的修饰键变化
    }
}
