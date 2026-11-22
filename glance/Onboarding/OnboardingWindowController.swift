//
//  OnboardingWindowController.swift
//  glance v2
//
//  Mac-native onboarding container: a normal centered window instead of the
//  old notch/dynamic-island panel. On a Mac mini (no physical notch) a floating
//  panel pinned to the screen top reads as broken; a standard window is what
//  Apple's own setup assistants use.
//
//  The step views themselves are unchanged pure SwiftUI — only the container
//  and its presentation change.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var host: NSHostingView<OnboardingNotchView>?
    private weak var controller: OnboardingController?
    /// Mirrors NotchOverlayController.phase for the few call sites that gate on it.
    private(set) var isOnboarding: Bool = false

    private override init() {}

    /// Present the onboarding flow in a centered, resizable-to-content window.
    func presentOnboarding(_ controller: OnboardingController) {
        self.controller = controller
        self.isOnboarding = true
        controller.onFirstRunComplete = { [weak self] in
            self?.dismissOnboarding()
        }

        // v2: window hugs content — size comes from the window-specific table,
        // and the view reports step changes so the window resizes precisely.
        let initial = OnboardingMetrics.windowSize(for: controller.step)
        let host = NSHostingView(rootView: OnboardingNotchView(
            controller: controller,
            windowMode: true,
            onSizeChange: { [weak self] size in
                Task { @MainActor [weak self] in self?.resize(to: size) }
            }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initial.width, height: initial.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Glance 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.center()
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        self.host = host

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Resize the window to exactly fit the current step's content, staying centered.
    private func resize(to size: CGSize) {
        guard let window else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let frame = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        window.setFrame(frame, display: true, animate: true)
    }

    /// Close the onboarding window. Guarded so a late completion can't close a
    /// newly-opened settings window by mistake.
    func dismissOnboarding() {
        guard isOnboarding else { return }
        isOnboarding = false
        controller = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        host = nil
    }

}

// MARK: - NSWindowDelegate

extension OnboardingWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.isOnboarding else { return }
            self.controller?.teardown()
            self.isOnboarding = false
            self.controller = nil
        }
    }
}
