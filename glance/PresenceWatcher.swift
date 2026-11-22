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
@preconcurrency import Vision

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
                // 两个功能都关闭时无需高频唤醒：默认配置下 autoLockOnAway=false、
                // wakeOnApproach=false，原来仍每 2 秒空转判断一次，白白耗电。
                // 关闭时降到 30 秒巡检一次设置是否已开启；开启后恢复 2 秒。
                let settings = GlanceSettings.shared
                let idle = !settings.autoLockOnAway && !settings.wakeOnApproach
                let nanoseconds: UInt64 = idle ? 30_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self?.tickAwayCheck()
            }
        }
    }

    private func tickAwayCheck() async {
        let settings = GlanceSettings.shared
        guard settings.autoLockOnAway, settings.isFaceUnlockEnabled else { return }
        guard !isScreenAsleep, !isScreenLocked else { return }
        guard !isCapturing, !MenuBarNotchController.shared.isScanning else { return }
        // v2: 每个 2 秒 tick 都轮询手柄（快照对比，极廉价），与键鼠同级别纳入活动判定。
        // 必须在 60 秒节流之前 poll，否则手柄活动精度会掉到 60 秒。
        GamepadActivityMonitor.poll()
        guard Date().timeIntervalSince(lastAwayCheck) >= TimeInterval(settings.awayCheckSeconds) else { return }

        // v2 修复：用户近期有鼠标/键盘操作就不判离场。以前只看摄像头有没有脸，
        // 人在用电脑但脸暂时偏离镜头时会累积 missingStreak 被误锁。
        if Self.userWasActiveRecently(within: TimeInterval(settings.awayCheckSeconds)) {
            missingStreak = 0
            lastAwayCheck = Date()
            return
        }

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
            var quietStreak = 0  // 连续"有帧但没脸"的次数——久无人时用于降频
            self.noFrameStreak = 0
            var loggedPowerLoss = false
            GlanceLog.write("走近侦测：开始")

            while !Task.isCancelled {
                // v2 修复：USB 摄像头在长时间睡眠/锁屏后会断电断流。旧逻辑连续 7 次
                // 取不到帧就永久放弃，导致唤醒后走近再也不侦测，必须手动解锁一次才恢复。
                // 改成退避重试：失败越多间隔越长（省电），但永不放弃——供电恢复后自动接管。
                // 同时久无人（quietStreak）也逐步拉长间隔；一旦检测到脸立刻回到 2 秒。
                let frameBackoff = min(2 + self.noFrameStreak * 2, 15)
                let quietBackoff = min(2 + quietStreak, 8)
                let interval = max(frameBackoff, quietBackoff)
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.isScreenAsleep || self.isScreenLocked else { return }

                guard let hasFace = await self.captureAndDetectFace(timeout: 2.0) else {
                    self.noFrameStreak += 1
                    if self.noFrameStreak == 4 && !loggedPowerLoss {
                        GlanceLog.write("走近侦测：相机暂不可读（可能断电），退避重试中")
                        loggedPowerLoss = true
                    }
                    continue
                }
                if loggedPowerLoss {
                    GlanceLog.write("走近侦测：相机已恢复")
                    loggedPowerLoss = false
                }
                self.noFrameStreak = 0
                if hasFace {
                    quietStreak = 0  // 有人立即恢复高频，保证走近响应
                } else {
                    quietStreak += 1
                }
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
    /// v2 省电优化：先把帧缩到 320px 再检测——纯存在检测不需要高清，
    /// Vision 在 320px 判"有没有脸"依旧可靠，但推理开销约为 640px 的 1/4。
    nonisolated private static func containsFace(_ image: CGImage) -> Bool {
        let target: CGFloat = 320
        let longEdge = CGFloat(max(image.width, image.height))
        let detectionImage: CGImage
        if longEdge > target {
            let scale = target / longEdge
            let w = Int(CGFloat(image.width) * scale)
            let h = Int(CGFloat(image.height) * scale)
            detectionImage = Self.downsample(image, to: CGSize(width: w, height: h)) ?? image
        } else {
            detectionImage = image
        }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: detectionImage, options: [:])
        do {
            try handler.perform([request])
            return !(request.results?.isEmpty ?? true)
        } catch {
            return false
        }
    }

    /// Downsamples a CGImage for cheap presence detection.
    nonisolated private static func downsample(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 近期（within 秒内）是否有鼠标或键盘活动。用于避免"人在用电脑但脸偏离镜头"被误判离场。
    nonisolated private static func userWasActiveRecently(within seconds: TimeInterval) -> Bool {
        let mouse = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let key = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        // 手柄快照已在 tickAwayCheck 每次 tick 时 poll 过，这里只读时间戳。
        let gamepad = GamepadActivityMonitor.secondsSinceActivity()
        return min(mouse, key, gamepad) <= seconds
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
