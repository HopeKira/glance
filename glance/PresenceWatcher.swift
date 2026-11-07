//
//  PresenceWatcher.swift
//  glance
//
//  两件事，都基于同一个低功耗相机（≤640×480@5fps，只做人脸检测、不做识别）：
//
//  1. 离开自动锁屏：解锁状态下每隔一段时间抓一帧，连续两次看不到人脸就触发锁屏（⌃⌘Q）。
//     息屏仍交给系统设置，本功能只管「锁」。
//  2. 走近自动亮屏：屏幕睡着后持续低频侦测，连续两次看到人脸就点亮显示器，
//     随后由 Face Unlock 现有的唤醒流程刷脸解锁。
//
//  相机在息屏时断流（部分 USB 相机会断电）则自动放弃，行为退回「按键盘唤醒」。
//

import AppKit
import Foundation
import Observation
import Vision

@Observable
@MainActor
final class PresenceWatcher {
    private let camera = CameraManager(prefersLowPower: true)

    private var awayTask: Task<Void, Never>?
    private var returnTask: Task<Void, Never>?
    private var isCapturing = false

    private var isScreenAsleep = false
    private var isScreenLocked = false
    private var lastAwayCheck = Date.distantPast
    private var missingStreak = 0
    private var noFrameStreak = 0

    private var observers: [NSObjectProtocol] = []

    // MARK: - 生命周期

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenAsleep = true
                self?.startReturnWatchIfNeeded()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenAsleep = false
                self?.stopReturnWatch(reason: "屏幕已唤醒")
            }
        })

        // 锁屏/解锁：分布式通知，系统层面可靠
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = true
                self?.startReturnWatchIfNeeded()
            }
        })
        observers.append(distributed.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = false
                self?.missingStreak = 0
                self?.stopReturnWatch(reason: "已解锁")
            }
        })

        startAwayLoop()
    }

    // MARK: - 离开自动锁屏

    private func startAwayLoop() {
        awayTask?.cancel()
        awayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.tickAwayCheck()
            }
        }
    }

    private func tickAwayCheck() async {
        let settings = GlanceSettings.shared
        guard settings.autoLockOnAway, settings.isFaceUnlockEnabled else { return }
        guard !isScreenAsleep, !isScreenLocked else { return }
        guard !isCapturing, NotchOverlayController.shared.phase == .closed else { return }
        guard Date().timeIntervalSince(lastAwayCheck) >= TimeInterval(settings.awayCheckSeconds) else { return }

        lastAwayCheck = Date()
        guard let hasFace = await captureAndDetectFace(timeout: 2.5) else {
            // 这次没拿到画面，不计入"没人"
            return
        }

        if hasFace {
            missingStreak = 0
            return
        }
        missingStreak += 1
        GlanceLog.write("离场检测：连续 \(missingStreak) 次未检测到人脸")
        guard missingStreak >= 2 else { return }

        missingStreak = 0
        GlanceLog.write("离场检测：判定已离开，锁屏")
        Self.lockScreen()
        isScreenLocked = true
        startReturnWatchIfNeeded()
    }

    // MARK: - 走近自动亮屏

    private func startReturnWatchIfNeeded() {
        guard GlanceSettings.shared.wakeOnApproach, GlanceSettings.shared.isFaceUnlockEnabled else { return }
        guard returnTask == nil else { return }

        returnTask = Task { [weak self] in
            guard let self else { return }
            var faceHits = 0
            self.noFrameStreak = 0
            GlanceLog.write("走近侦测：开始")

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.isScreenAsleep || self.isScreenLocked else { return }

                guard let hasFace = await self.captureAndDetectFace(timeout: 2.0) else {
                    self.noFrameStreak += 1
                    if self.noFrameStreak >= 7 {
                        GlanceLog.write("走近侦测：息屏期间取不到画面，放弃（相机可能已断电）")
                        self.stopReturnWatch(reason: "相机无画面")
                        return
                    }
                    continue
                }
                self.noFrameStreak = 0
                faceHits = hasFace ? faceHits + 1 : 0

                if faceHits >= 2 {
                    GlanceLog.write("走近侦测：检测到人脸，唤醒显示器")
                    Self.wakeDisplay()
                    self.stopReturnWatch(reason: "已唤醒")
                    return
                }
            }
        }
    }

    private func stopReturnWatch(reason: String) {
        guard returnTask != nil else { return }
        returnTask?.cancel()
        returnTask = nil
        camera.stop()
        GlanceLog.write("走近侦测：结束（\(reason)）")
    }

    // MARK: - 相机

    /// 开相机 → 等一帧 → 判断有没有脸 → 关相机。为省电是「用完就关」：
    /// 日常每隔 awayCheckSeconds 开一次，息屏时每 2 秒开一次。
    private func captureAndDetectFace(timeout: TimeInterval) async -> Bool? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer {
            isCapturing = false
            camera.stop()
        }

        await camera.start()
        if camera.errorMessage != nil { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if let frame = camera.currentFrame {
                let image = frame.image
                return await Task.detached(priority: .utility) { Self.containsFace(image) }.value
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 只问「画面里有没有脸」，不认人、不算特征。
    nonisolated private static func containsFace(_ image: CGImage) -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return !(request.results?.isEmpty ?? true)
        } catch {
            return false
        }
    }

    /// ⌃⌘Q —— 系统自带的「锁定屏幕」，比私有 API 稳，也不需要额外权限。
    nonisolated private static func lockScreen() {
        let source = CGEventSource(stateID: .hidSystemState)
        let qKey: CGKeyCode = 0x0C
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: isDown)
            event?.flags = [.maskControl, .maskCommand]
            event?.post(tap: .cghidEventTap)
        }
    }

    /// `caffeinate -u` 模拟一次用户活动，点亮显示器。
    nonisolated private static func wakeDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "2"]
        try? process.run()
    }
}
