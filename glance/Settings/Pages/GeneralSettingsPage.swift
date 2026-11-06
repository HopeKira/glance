//
//  GeneralSettingsPage.swift
//  glance
//

import OSLog
import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    /// Refreshed on `didChangeScreenParametersNotification` so the picker
    /// reflects displays connecting/disconnecting while Settings is open.
    @State private var screens: [NSScreen] = NSScreen.screens
    /// Refreshed when the app regains focus, so granting the permission in
    /// System Settings clears the prompt below without a relaunch.
    @State private var inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
    @State private var isRecordingHotKey = false
    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController`, not a local copy — the session can be
    /// auto-locked while this page is visible.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    private var needsInputMonitoring: Bool {
        settings.unlockTriggers.contains(.onSpace) && inputMonitoring != .granted
    }

    /// Dev-only: under Xcode the reading above is Xcode's permission, not
    /// glance's, so it's meaningless. See `SpaceKeyMonitor.isLaunchedByXcode`.
    private var hasInheritedXcodePermission: Bool {
        settings.unlockTriggers.contains(.onSpace) && SpaceKeyMonitor.isLaunchedByXcode
    }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            unlockedState
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .sheet(isPresented: $isRecordingHotKey) {
            HotKeyRecorderSheet { keyCode, modifiers in
                if let keyCode, let modifiers {
                    settings.manualHotKeyCode = keyCode
                    settings.manualHotKeyModifiers = modifiers
                }
                isRecordingHotKey = false
            }
        }
        .onAppear { pocController.refreshCredentialStatus() }
        // The password prompt runs in the notch, outside this view's hierarchy,
        // so refresh the session state when that flow finishes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "会话已锁定",
            buttonTitle: isUnlocking ? "正在验证…" : "解锁会话",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(title: "登录时启动") {
                    GlanceToggle(isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { newValue in
                            launchAtLoginEnabled = newValue
                            do {
                                try LaunchAtLogin.setEnabled(newValue)
                                launchAtLoginError = nil
                            } catch {
                                launchAtLoginEnabled = !newValue
                                launchAtLoginError = error.localizedDescription
                            }
                        }
                    ))
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "在菜单栏中显示") {
                    GlanceToggle(isOn: $settings.showsInMenuBar)
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "启用面容解锁") {
                    GlanceToggle(isOn: $coordinator.isEnabled)
                }
                SettingsGroupDivider()
                SettingsRowContent(
                    title: "刷脸输入密码快捷键",
                    subtitle: "在任意输入框按此组合键，刷脸后自动输入密码"
                ) {
                    Button {
                        isRecordingHotKey = true
                    } label: {
                        Text(HotKeyDisplay.string(
                            keyCode: settings.manualHotKeyCode,
                            modifiers: settings.manualHotKeyModifiers
                        ))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
                SettingsGroupDivider()
                UnlockTriggerPicker(selection: $settings.unlockTriggers, isEnabled: coordinator.isEnabled)
                SettingsGroupDivider()
                displayPicker()
            }

            SettingsGroup {
                SettingsRowContent(
                    title: "离开时自动息屏",
                    subtitle: "超过设定时间没有任何键鼠操作就关闭显示器；回来时仍由人脸解锁"
                ) {
                    GlanceToggle(isOn: $settings.autoSleepOnAway)
                }
                if settings.autoSleepOnAway {
                    SettingsGroupDivider()
                    SettingsSlider(
                        title: "空闲时长",
                        value: Binding(
                            get: { Float(settings.autoSleepIdleMinutes) },
                            set: { settings.autoSleepIdleMinutes = Int($0.rounded()) }
                        ),
                        range: 1...30,
                        format: { "\(Int($0)) 分钟" }
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
            }
            .onChange(of: settings.unlockTriggers) { oldValue, newValue in
                // Only prompt on the transition into selecting "按空格时".
                SpaceKeyMonitor.log.info("unlockTriggers changed: old=\(String(describing: oldValue), privacy: .public) new=\(String(describing: newValue), privacy: .public) state=\(String(describing: inputMonitoring), privacy: .public)")
                if newValue.contains(.onSpace), !oldValue.contains(.onSpace), inputMonitoring != .granted {
                    SpaceKeyMonitor.requestInputMonitoringAccess()
                    // tccd flips notDetermined -> denied just after the call
                    // returns, so re-read on the next beat rather than inline.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                    }
                }
            }
            if let launchAtLoginError {
                SettingsCaption(text: launchAtLoginError)
            }
            if hasInheritedXcodePermission {
                SettingsCaption(text: "Running from Xcode — permission checks resolve against Xcode’s grants, not glance’s, so this reading is meaningless. Launch glance.app on its own to see the real state.")
            } else if needsInputMonitoring {
                inputMonitoringNotice()
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "行为")
                SettingsGroup {
                    SettingsRowContent(title: "悬停刘海时重试") {
                        GlanceToggle(isOn: $settings.retryOnHover)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(title: "失败后自动重试一次") {
                        GlanceToggle(isOn: $settings.autoRetryOnce)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(title: "触感反馈") {
                        GlanceToggle(isOn: $settings.hapticFeedbackEnabled)
                    }
                    SettingsGroupDivider()
                    SettingsSteppedSliderRowContent(
                        title: "面容检测时长",
                        valueLabel: "\(settings.faceDetectionSeconds)s",
                        index: Binding(
                            get: { Double(settings.faceDetectionSeconds - GlanceSettings.faceDetectionRange.lowerBound) },
                            set: { settings.faceDetectionSeconds = GlanceSettings.faceDetectionRange.lowerBound + Int($0.rounded()) }
                        ),
                        stopCount: GlanceSettings.faceDetectionRange.count
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "动画")
                SettingsGroup {
                    SettingsRowContent(title: "显示动画") {
                        GlanceToggle(isOn: $settings.showUnlockAnimation)
                    }
                    SettingsGroupDivider()
                    UnlockAnimationPicker(
                        selection: $settings.unlockAnimationStyle,
                        isEnabled: settings.showUnlockAnimation
                    )
                }
            }
        }
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }

    /// Shown while "按空格时" is selected but Input Monitoring isn't granted.
    private func inputMonitoringNotice() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption(text: "“按空格时”会直接读取键盘，以识别锁屏界面上的空格键，这需要“辅助功能”权限——与 Glance 输入密码所用的权限相同。请在“隐私与安全性”→“辅助功能”中打开 Glance，然后退出并重新打开 Glance。")
            Button("打开“辅助功能”设置") {
                // Covers the rare install with no Accessibility grant at all.
                SpaceKeyMonitor.requestInputMonitoringAccess()
                openSystemSettings(pane: "Privacy_Accessibility")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(GlanceTheme.accent)
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func displayPicker() -> some View {
        SettingsRowContent(title: "显示在") {
            SettingsMenuPickerPill(label: displayLabel) {
                Button("主显示器") {
                    settings.preferredDisplayID = nil
                    settings.preferredDisplayName = nil
                }
                ForEach(screens.compactMap(NamedScreen.init), id: \.id) { screen in
                    Button(screen.name) {
                        settings.preferredDisplayID = screen.id
                        settings.preferredDisplayName = screen.name
                    }
                }
            }
        }
    }

    /// A connected screen with its stable ID already unwrapped, so the
    /// picker's `ForEach` doesn't need to filter/force-unwrap inline.
    private struct NamedScreen {
        let id: String
        let name: String

        init?(_ screen: NSScreen) {
            guard let id = screen.stableDisplayID else { return nil }
            self.id = id
            self.name = screen.localizedName
        }
    }

    private var displayLabel: String {
        guard let targetID = settings.preferredDisplayID else { return "主显示器" }
        if let connected = screens.first(where: { $0.stableDisplayID == targetID }) {
            return connected.localizedName
        }
        // Picked, but not currently connected — say so rather than showing
        // a bare ID or falling back to another display's name.
        guard let name = settings.preferredDisplayName else { return "所选显示器（已断开）" }
        return "\(name) (disconnected)"
    }
}

/// 录制快捷键的小弹窗：按任意带修饰键的组合，Esc 取消。
private struct HotKeyRecorderSheet: View {
    let onCapture: (Int?, Int?) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("按下新的快捷键")
                .font(.system(size: 14, weight: .semibold))
            Text("需要至少一个修饰键（⌃ ⌥ ⇧ ⌘），Esc 取消")
                .font(.caption)
                .foregroundStyle(.secondary)
            HotKeyRecorderView(onCapture: onCapture)
                .frame(width: 260, height: 76)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            Button("取消") { onCapture(nil, nil) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 320)
    }
}
