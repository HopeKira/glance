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

        // v2: fixed window sized to the largest step (enroll). No dynamic
        // resize — setFrame during SwiftUI's layout pass crashed with
        // NSWindow _postWindowNeedsUpdateConstraints. Content views keep their
        // own step-specific frames and sit centered in this window.
        let windowSize = OnboardingMetrics.windowSize(for: .enroll)
        let host = NSHostingView(rootView: OnboardingNotchView(
            controller: controller,
            windowMode: true
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height),
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
