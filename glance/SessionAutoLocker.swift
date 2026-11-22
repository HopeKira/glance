//
//  SessionAutoLocker.swift
//  glance
//
//  Enforces `GlanceSettings.autoLockInterval`: re-locks the session once idle past the user's chosen limit.
//

import Foundation
import AppKit

@MainActor
final class SessionAutoLocker {
    private let pocController: POCController
    nonisolated(unsafe) private var timer: Timer?
    /// 保存 wake 观察者 token，deinit 时移除，避免对象重建时累积孤儿观察者。
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    /// Coarse on purpose — the shortest selectable limit is a full day, and the decision compares timestamps, not ticks.
    private let checkInterval: TimeInterval = 5 * 60

    init(pocController: POCController) {
        self.pocController = pocController
        // `.common` so the countdown keeps being checked during tracking runloop modes (an open menu, a drag).
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Also evaluate on wake: no timer fires during sleep, but the elapsed time still counts as idle once compared.
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        evaluate()
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Routed through `POCController.lockSession()` rather than `SecureCredentialManager` directly, so the Settings UI's
    /// `isSessionUnlocked` flag doesn't go stale.
    func evaluate() {
        guard SecureCredentialManager.isSessionUnlocked,
              let lastActivityAt = SecureCredentialManager.lastActivityAt
        else { return }

        // A "Never" preference still loses the in-memory session key on app
        // relaunch; it only disables the idle-timeout lock while Glance runs.
        guard let idleLimit = GlanceSettings.shared.autoLockInterval.duration else { return }
        guard Date().timeIntervalSince(lastActivityAt) >= idleLimit else { return }

        pocController.lockSession()
    }
}
