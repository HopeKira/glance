//
//  AwayAutoSleeper.swift
//  glance
//
//  「离开自动息屏」：用系统输入空闲时间判断人是否离开（不是摄像头常开，几乎零功耗），
//  超过阈值就关闭显示器；回来时由 Face Unlock 现有的唤醒触发接住，刷脸解锁。
//

import Foundation
import CoreGraphics
import Observation

@Observable
@MainActor
final class AwayAutoSleeper {
    private var timer: Timer?
    /// 一次空闲只关一次屏，避免显示器刚睡下又被自己重复触发。
    private var hasSleptForCurrentIdle = false
    private(set) var lastSleepAt: Date?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let settings = GlanceSettings.shared
        guard settings.autoSleepOnAway else { return }

        let idle = Self.secondsSinceLastInput()
        // 有任何输入就解除"已关屏"标记，下次空闲可以再关一次。
        if idle < 60 { hasSleptForCurrentIdle = false }

        let threshold = TimeInterval(settings.autoSleepIdleMinutes * 60)
        guard idle >= threshold, !hasSleptForCurrentIdle else { return }

        hasSleptForCurrentIdle = true
        lastSleepAt = Date()
        GlanceLog.write("自动息屏：空闲 \(Int(idle)) 秒，关闭显示器")
        Self.sleepDisplay()
    }

    /// `.combinedSessionState` + kCGAnyInputEventType — 键鼠任意输入都算。
    nonisolated static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    nonisolated static func sleepDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }
}
