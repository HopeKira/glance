//
//  GamepadActivityMonitor.swift
//  glance v2
//
//  Lightweight gamepad activity tracking so controller play counts as "user is
//  active" for away-lock, on par with mouse/keyboard. Uses only the public
//  GameController framework — no HID permission needed for reading button state
//  of already-paired controllers.
//

import Foundation
import GameController

/// Polls connected controllers' button/axis state and records the last time
/// any input was active. Cheap: GCController state is an in-memory snapshot.
enum GamepadActivityMonitor {
    nonisolated(unsafe) private static var lastActiveAt: Date = .distantPast
    nonisolated(unsafe) private static var previousSnapshot: [String: Float] = [:]

    /// Call from the same loop that checks mouse/keyboard activity. Refreshes
    /// the timestamp if any controller button/axis changed since last poll.
    nonisolated static func poll() {
        let controllers = GCController.controllers()
        guard !controllers.isEmpty else {
            previousSnapshot.removeAll()
            return
        }
        var current: [String: Float] = [:]
        var changed = false
        for (index, controller) in controllers.enumerated() {
            let prefix = "\(index)"
            if let pad = controller.extendedGamepad {
                let values: [String: Float] = [
                    "a": pad.buttonA.value, "b": pad.buttonB.value,
                    "x": pad.buttonX.value, "y": pad.buttonY.value,
                    "l1": pad.leftShoulder.value, "r1": pad.rightShoulder.value,
                    "l2": pad.leftTrigger.value, "r2": pad.rightTrigger.value,
                    "dpadUp": pad.dpad.up.value, "dpadDown": pad.dpad.down.value,
                    "dpadLeft": pad.dpad.left.value, "dpadRight": pad.dpad.right.value,
                    "lsX": pad.leftThumbstick.xAxis.value, "lsY": pad.leftThumbstick.yAxis.value,
                    "rsX": pad.rightThumbstick.xAxis.value, "rsY": pad.rightThumbstick.yAxis.value,
                    "menu": pad.buttonMenu.value, "options": pad.buttonOptions?.value ?? 0,
                ]
                for (key, value) in values {
                    current[prefix + key] = value
                    if abs(value - (previousSnapshot[prefix + key] ?? 0)) > 0.08 {
                        changed = true
                    }
                }
            } else if let pad = controller.gamepad {
                let values: [String: Float] = [
                    "a": pad.buttonA.value, "b": pad.buttonB.value,
                    "x": pad.buttonX.value, "y": pad.buttonY.value,
                    "l1": pad.leftShoulder.value, "r1": pad.rightShoulder.value,
                    "dpadUp": pad.dpad.up.value, "dpadDown": pad.dpad.down.value,
                    "dpadLeft": pad.dpad.left.value, "dpadRight": pad.dpad.right.value,
                ]
                for (key, value) in values {
                    current[prefix + key] = value
                    if abs(value - (previousSnapshot[prefix + key] ?? 0)) > 0.08 {
                        changed = true
                    }
                }
            }
        }
        previousSnapshot = current
        if changed {
            lastActiveAt = Date()
        }
    }

    /// Seconds since the last detected gamepad input, or .greatestFiniteMagnitude if never.
    nonisolated static func secondsSinceActivity() -> TimeInterval {
        lastActiveAt == .distantPast
            ? .greatestFiniteMagnitude
            : Date().timeIntervalSince(lastActiveAt)
    }
}
