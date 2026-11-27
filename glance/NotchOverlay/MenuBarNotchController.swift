//
//  MenuBarNotchController.swift
//  glance v2
//
//  Mac-native unlock feedback: a Liquid-Glass capsule that grows DOWN from the
//  menu bar, instead of faking an iPhone Dynamic Island on a bezel-less Mac mini.
//
//  Design rationale (Apple HIG / DTS, 2026):
//  - "The closest conceptual equivalent to the Dynamic Island on macOS is a
//     Menu Bar Extra … Do not try to force a literal Dynamic Island UI onto
//     the Mac desktop."  So the capsule is anchored to the menu bar line.
//  - macOS 27.3 puts native Live Activities in the menu bar via MenuBarAgent;
//    the menu bar — not a screen notch — is Apple's standard glanceable surface.
//
//  Lock screen: the menu bar is covered by the loginwindow. We reuse the existing
//  SkyLight space delegation to lift this panel to a lock-screen-visible level
//  while a scan is active, and return it to normal windows the rest of the time.
//

import AppKit
import SwiftUI
import Observation

// MARK: - Visual state

enum MenuBarNotchPhase: Equatable {
    case closed
    case scanning
    case success
    case failure
}

// MARK: - The panel

/// Borderless, non-activating panel pinned just below the menu bar's center.
private final class MenuBarNotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
    }
}

// MARK: - The hosted SwiftUI view

private struct MenuBarNotchView: View {
    let phase: MenuBarNotchPhase
    /// v2: 悬停到失败/待命胶囊时触发一次重试（原版 glance 的 hover-to-retry）。
    var onActivate: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 9) {
            switch phase {
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                Text("正在识别…")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                Text("已解锁")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                Text("未识别 · 悬停重试")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            case .closed:
                EmptyView()
            }
        }
        .fixedSize(horizontal: true, vertical: false) // 禁止压缩导致文字换行
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 34)
        // Native Liquid Glass, matching the Settings redesign.
        .glassEffect(.regular, in: Capsule())
        // Grow down out of the menu bar, not expand from a screen notch.
        .scaleEffect(y: phase == .closed ? 0.2 : 1, anchor: .top)
        .opacity(phase == .closed ? 0 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: phase)
        .onHover { hovering in
            // v2: 失败/待命态悬停触发一次重试（原版 glance hover-to-retry）。
            guard hovering else { return }
            onActivate?()
        }
        .contentShape(Capsule())
    }
}

// MARK: - Controller

@MainActor
final class MenuBarNotchController {
    static let shared = MenuBarNotchController()

    private let panel: MenuBarNotchPanel
    private var hosting: NSHostingView<MenuBarNotchView>?
    private var resolveTask: Task<Void, Never>?
    private var isDelegatedToLockScreen = false
    /// v2: hover-to-retry 回调，由 FaceUnlock 在失败时设置。
    private var onActivate: (() -> Void)?
    /// 失败后胶囊保持可见、可悬停的最长时间；超时才真正隐藏。
    private let armedTimeout: Duration = .seconds(30)

    /// Mirrors NotchOverlayController's surface so callers can swap implementations cleanly.
    private(set) var phase: MenuBarNotchPhase = .closed
    var isScanning: Bool { phase == .scanning }
    /// v2: 失败后胶囊留在屏幕上等悬停时为 true。
    private(set) var isArmed: Bool = false

    let successHoldDuration: Duration = .milliseconds(900)
    let failureHoldDuration: Duration = .milliseconds(1600)
    let collapseAnimationDuration: Duration = .milliseconds(320)

    private init() {
        panel = MenuBarNotchPanel(contentRect: NSRect(x: 0, y: 0, width: 170, height: 34))
        let host = NSHostingView(rootView: MenuBarNotchView(phase: .closed))
        host.frame = NSRect(x: 0, y: 0, width: 170, height: 34)
        panel.contentView = host
        hosting = host
    }

    /// 重建 SwiftUI rootView，把当前 hover 回调带上。
    private func render() {
        hosting?.rootView = MenuBarNotchView(phase: phase, onActivate: { [weak self] in
            self?.activate()
        })
    }

    /// 悬停触发一次重试（仅失败/待命态）。
    private func activate() {
        guard phase == .failure || (phase == .closed && isArmed) else { return }
        guard let onActivate else { return }
        resolveTask?.cancel()
        resolveTask = nil
        isArmed = false
        panel.ignoresMouseEvents = true
        onActivate()
    }

    // MARK: Lifecycle

    /// Begin the scanning animation. Safe to call repeatedly.
    func beginScanning() {
        resolveTask?.cancel()
        resolveTask = nil
        positionBelowMenuBar()
        phase = .scanning
        isArmed = false
        panel.ignoresMouseEvents = true
        render()
        delegateToLockScreenIfNeeded()
        panel.orderFrontRegardless()
    }

    /// Compatibility alias used by Settings' live preview and onboarding call sites.
    func present(styleOverride: UnlockAnimationStyle? = nil, onRetry: (() -> Void)? = nil) {
        if let onRetry { self.onActivate = onRetry }
        beginScanning()
    }

    /// Resolve with success/failure feedback, then auto-collapse.
    /// v2: 失败后不立即隐藏——失败胶囊保持可见且可悬停，等用户 hover 触发一次重试，
    /// 超过 armedTimeout 仍无人操作才真正隐藏。这是原版 glance 的 hover-to-retry。
    func finish(success: Bool) {
        resolveTask?.cancel()
        phase = success ? .success : .failure
        render()
        if success {
            panel.ignoresMouseEvents = true
            isArmed = false
            let hold = successHoldDuration
            resolveTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: hold)
                guard !Task.isCancelled else { return }
                self.collapse()
            }
        } else {
            // 失败态：留在屏幕上、可悬停、保持锁屏委托。
            isArmed = true
            panel.ignoresMouseEvents = false
            delegateToLockScreenIfNeeded()
            panel.orderFrontRegardless()
            resolveTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.armedTimeout)
                guard !Task.isCancelled else { return }
                self.collapse()
            }
        }
    }

    /// Collapse back into the menu bar and release the lock-screen space.
    func collapse() {
        phase = .closed
        isArmed = false
        panel.ignoresMouseEvents = true
        render()
        releaseLockScreenDelegation()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.collapseAnimationDuration)
            guard self.phase == .closed else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Cancel any animation immediately (e.g. app disabling face unlock).
    func cancel() {
        resolveTask?.cancel()
        resolveTask = nil
        collapse()
    }

    // MARK: Arm / disarm (call-site compatibility)
    //
    // The old notch had a hover-to-retry "armed" pill. A menu-bar capsule has
    // no hover target, so arming is a no-op; these exist so the coordinator's
    // trigger logic can stay uniform across both animations.

    /// v2: 保存 hover 触发的重试回调（失败胶囊悬停时用）。
    func arm(onActivate: (() -> Void)? = nil) {
        if let onActivate { self.onActivate = onActivate }
    }

    /// Hide any in-flight animation when face unlock is disabled.
    func disarm() {
        cancel()
    }

    // MARK: Geometry

    /// Anchors the capsule centered on the menu bar's bottom edge of the active screen.
    private func positionBelowMenuBar() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let f = screen.frame
        let menuBarBottom = f.maxY - NSStatusBar.system.thickness
        let w: CGFloat = 170
        let h: CGFloat = 34
        let x = f.midX - w / 2
        // A few points below the menu bar so it reads as "growing out of" it.
        let y = menuBarBottom - h - 6
        let newFrame = NSRect(x: x, y: y, width: w, height: h)
        panel.setFrame(newFrame, display: false)
    }

    // MARK: Lock screen delegation (private SkyLight, best-effort)

    private func delegateToLockScreenIfNeeded() {
        guard LockMonitor.isScreenActuallyLocked(),
              let skyLight = NotchSkyLight.shared,
              !isDelegatedToLockScreen else { return }
        skyLight.delegate(panel)
        isDelegatedToLockScreen = true
    }

    private func releaseLockScreenDelegation() {
        guard isDelegatedToLockScreen, let skyLight = NotchSkyLight.shared else { return }
        skyLight.undelegate(panel)
        isDelegatedToLockScreen = false
    }
}
