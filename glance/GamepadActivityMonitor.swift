//
//  GamepadActivityMonitor.swift
//  glance v2
//
//  v2 重写：GameController.framework 只能看到 MFi / 系统认证手柄 —— 实测用户的
//  第三方手柄（GamePad-1 / Pro Controller 等）GCController.controllers() 为 0，
//  旧实现完全空转，打游戏时照样被判离场锁屏。
//
//  改用 IOKit HID 事件回调（与 SpaceKeyMonitor 同一套、靠 Accessibility 权限即可）：
//  监听所有 HID 设备的按钮/轴 value 变化，实时记录最后活动时间戳。任何手柄按键、
//  扳机、摇杆、十字键一动就刷新——不依赖 GameController、不轮询、不漏状态相同的键。
//

import Foundation
import IOKit.hid
import OSLog

enum GamepadActivityMonitor {

    nonisolated(unsafe) private static var manager: IOHIDManager?
    nonisolated(unsafe) private static var lastActiveAt: Date = .distantPast
    nonisolated(unsafe) private static var started = false

    /// Start listening once. Idempotent. Fails closed if HID access isn't granted.
    static func start() {
        guard !started else { return }
        started = true

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            GlanceLog.write("手柄监控：HID 权限未授予")
            return
        }

        // Match every HID device — we only care about value changes on buttons/axes.
        IOHIDManagerSetDeviceMatching(mgr, nil)
        IOHIDManagerRegisterInputValueCallback(mgr, { _, _, _, value in
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            // GenericDesktop (axes/hat switch), Button (face/shoulder buttons).
            guard page == UInt32(kHIDPage_GenericDesktop) || page == UInt32(kHIDPage_Button) else { return }
            GamepadActivityMonitor.recordActivity()
        }, nil)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            GlanceLog.write("手柄监控：IOHIDManagerOpen 失败 0x\(String(result, radix: 16))")
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        manager = mgr
        GlanceLog.write("手柄监控：已启动 HID 活动监听")
    }

    nonisolated private static func recordActivity() {
        lastActiveAt = Date()
    }

    /// Kept for call-site compatibility — no-op now (event-driven, not polled).
    nonisolated static func poll() {}

    /// Seconds since the last detected HID (gamepad) input.
    nonisolated static func secondsSinceActivity() -> TimeInterval {
        lastActiveAt == .distantPast
            ? .greatestFiniteMagnitude
            : Date().timeIntervalSince(lastActiveAt)
    }
}
