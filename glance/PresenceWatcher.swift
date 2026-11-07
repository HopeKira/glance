//
//  PresenceWatcher.swift
//  glance
//
//  「回来就自动亮屏」：显示器睡着后进入低频待机侦测——用最小分辨率、5fps 的相机出流，
//  每 2 秒取一帧只跑人脸检测（不识别、不提取 embedding）。连续两次看到人脸就
//  模拟一次用户活动点亮显示器，随后由 Face Unlock 现有的唤醒流程接手刷脸解锁。
//
//  相机在息屏期间断流（部分 USB 相机会断电）时，取不到帧就自动放弃，行为退回「手动按键唤醒」。
//

import AppKit
import Foundation
import Observation
import Vision

@Observable
@MainActor
final class PresenceWatcher {
    /// 只用于待机侦测的低功耗相机；与解锁扫描用的相机互不干扰（不会同时开）。
    private let camera = CameraManager(prefersLowPower: true)

    private var watchTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private(set) var isWatching = false
    private var noFrameStreak = 0

    func startMonitoringScreenState() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.beginWatchingIfEnabled() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopWatching(reason: "屏幕已唤醒") }
        })
    }

    private func beginWatchingIfEnabled() {
        let settings = GlanceSettings.shared
        guard settings.isFaceUnlockEnabled else { return }
        guard settings.wakeOnApproach || settings.autoSleepOnAway else { return }
        guard !isWatching else { return }
        startWatching()
    }

    private func startWatching() {
        isWatching = true
        noFrameStreak = 0
        watchTask = Task { [weak self] in
            guard let self else { return }
            await self.camera.start()
            if let error = self.camera.errorMessage {
                GlanceLog.write("待机侦测：摄像头启动失败 \(error)")
                self.stopWatching(reason: error)
                return
            }
            GlanceLog.write("待机侦测：开始（\(self.camera.activeDeviceDescription)）")

            var faceHits = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                guard let frame = self.camera.currentFrame else {
                    self.noFrameStreak += 1
                    // 连续 15 秒（约 7 次）拿不到帧 → 相机在息屏时断流，放弃并说明
                    if self.noFrameStreak >= 7 {
                        GlanceLog.write("待机侦测：息屏期间取不到画面，放弃（相机可能已断电）")
                        self.stopWatching(reason: "相机无画面")
                        return
                    }
                    continue
                }
                self.noFrameStreak = 0

                let image = frame.image
                let hasFace = await Task.detached(priority: .utility) { Self.containsFace(image) }.value
                if hasFace {
                    faceHits += 1
                } else {
                    faceHits = 0
                }

                if faceHits >= 2 {
                    GlanceLog.write("待机侦测：检测到人脸，唤醒显示器")
                    Self.wakeDisplay()
                    self.stopWatching(reason: "已唤醒")
                    return
                }
            }
        }
    }

    private func stopWatching(reason: String) {
        guard isWatching else { return }
        isWatching = false
        watchTask?.cancel()
        watchTask = nil
        camera.stop()
        GlanceLog.write("待机侦测：结束（\(reason)）")
    }

    /// 只问「画面里有没有脸」，不认人、不算特征——这是把功耗压到最低的关键。
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

    /// `caffeinate -u` 会模拟一次用户活动，显示器随之点亮（比私有 API 稳）。
    nonisolated private static func wakeDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "2"]
        try? process.run()
    }
}
