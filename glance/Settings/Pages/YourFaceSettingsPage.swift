//
//  YourFaceSettingsPage.swift
//  glance
//
//  The multi-identity Your Face page. Every enrolled person gets a card:
//  name, an enable switch, per-sample capture-quality ticks, and
//  Recapture/Delete.
//

import SwiftUI

struct YourFaceSettingsPage: View {
    let environment: AppEnvironment
    @Bindable private var store = FaceEnrollmentStore.shared

    @State private var sessionError: String?
    @State private var isUnlocking = false
    @State private var identityPendingDeletion: FaceIdentity?
    /// Surfaced when an encrypted write fails (realistically: the session
    /// lapsed between rendering and tapping). The store rolls back on
    /// failure, so the control snaps back on its own — this explains why.
    @State private var writeError: String?

    /// Locked takes priority over enrollment status: `FaceIdentity` data is
    /// encrypted under the session key, so whether anyone is enrolled is
    /// unknown until the session is unlocked.
    private enum PageStateKind: Equatable {
        case locked
        case unreadable
        case notEnrolled
        case enrolled
    }

    private var stateKind: PageStateKind {
        if store.isLocked { return .locked }
        // Ahead of `.notEnrolled` — a failed decrypt looks like an empty
        // store, and offering "设置面容解锁" there would destroy the data.
        if store.loadFailure != nil { return .unreadable }
        return store.identities.isEmpty ? .notEnrolled : .enrolled
    }

    /// The notch hosts one flow at a time, so a second Add/Recapture would
    /// swap the content out from under a capture already in progress.
    private var enrollmentFlowIsRunning: Bool {
        NotchOverlayController.shared.phase == .onboarding
    }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(stateKind == .locked ? 1 : 0)
                .allowsHitTesting(stateKind == .locked)
                .accessibilityHidden(stateKind != .locked)

            unreadableState
                .opacity(stateKind == .unreadable ? 1 : 0)
                .allowsHitTesting(stateKind == .unreadable)
                .accessibilityHidden(stateKind != .unreadable)

            notEnrolledState
                .opacity(stateKind == .notEnrolled ? 1 : 0)
                .allowsHitTesting(stateKind == .notEnrolled)
                .accessibilityHidden(stateKind != .notEnrolled)

            enrolledState
                .opacity(stateKind == .enrolled ? 1 : 0)
                .allowsHitTesting(stateKind == .enrolled)
                .accessibilityHidden(stateKind != .enrolled)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: stateKind)
        .onAppear { store.reloadIfUnlocked() }
        // The enrollment flow runs in the notch, outside this view's
        // hierarchy, so nothing else prompts a re-check once it closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            store.reloadIfUnlocked()
        }
        .confirmationDialog(
            "删除这张已录入的面容？",
            isPresented: Binding(
                get: { identityPendingDeletion != nil },
                set: { if !$0 { identityPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: identityPendingDeletion
        ) { identity in
            Button("删除", role: .destructive) { delete(identity) }
            Button("取消", role: .cancel) { identityPendingDeletion = nil }
        } message: { identity in
            Text("\"\(identity.name)\" will stop being recognized until you enroll them again.")
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

    // MARK: - Unreadable

    /// Session open but the encrypted store didn't decrypt. Deliberately
    /// offers no enroll or delete action, since a write here would replace
    /// faces still on disk.
    private var unreadableState: some View {
        VStack(spacing: SettingsMetrics.emptyStateSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: SettingsMetrics.emptyStateIconSize, weight: .regular))
                .foregroundStyle(SettingsMetrics.qualityFairColor)

            Text("无法读取已录入的面容")
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textSecondary)

            SettingsCaption(text: store.loadFailure ?? "无法用当前会话密钥解密已保存的数据。")
                .multilineTextAlignment(.center)

            SettingsCaption(text: "没有删除任何内容，Glance 也不会覆盖它——在问题解决前无法进行录入。请退出并重新打开 Glance 重试。如果一直失败，说明会话密钥已与这份数据不匹配：在“密码”标签页删除已保存的密码即可同时清除两者，然后重新设置。")
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
    }

    // MARK: - Not enrolled

    private var notEnrolledState: some View {
        SettingsEmptyStateView(
            icon: "faceid",
            message: "面容录入",
            buttonTitle: "设置面容解锁",
            isButtonEnabled: !enrollmentFlowIsRunning,
            action: { OnboardingController.startEnrollmentOnly() }
        )
    }

    // MARK: - Enrolled

    private var enrolledState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            faceEncryptedCard
            identitiesHeader
            .padding(.bottom, -8)

            ForEach(store.identities) { identity in
                IdentityCard(
                    identity: identity,
                    // Face Lab is a debug-only, lazily-created tool. The live unlock
                    // pipeline is the authoritative embedder for this normal Settings check.
                    isStale: identity.isStale(comparedTo: environment.faceUnlockCoordinator.pipeline.embedder),
                    canStartFlow: !enrollmentFlowIsRunning,
                    isEnabled: enabledBinding(for: identity),
                    recapture: { OnboardingController.startRecapture(of: identity) },
                    delete: { identityPendingDeletion = identity }
                )
            }

            if !store.identities.isEmpty && store.activeIdentities.isEmpty {
                SettingsCaption(text: "没有启用任何身份——在重新开启至少一个身份之前，面容解锁不会识别任何人。")
            }

            if let writeError {
                SettingsCaption(text: writeError)
            }
        }
    }

    /// Mirrors the Password page's "密码已加密" row — both refer to
    /// the same session key.
    private var faceEncryptedCard: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("面容已加密")
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    Spacer(minLength: 8)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }

                Text("可录入多个身份，以便多人共用 Glance，或应对眼镜等配饰、不同表情与光照环境。这能提升识别质量。")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, 12)
        }
    }

    private var identitiesHeader: some View {
        HStack(spacing: 0) {
            SettingsSectionTitle(text: "身份")

            Button {
                OnboardingController.startAddIdentity()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(enrollmentFlowIsRunning)
            .opacity(enrollmentFlowIsRunning ? 0.4 : 1)
            .help("录入另一张面容")
            .padding(.trailing, SettingsMetrics.sectionTitleHorizontalInset)
            .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
        }
    }

    // MARK: - Actions

    /// Reads through to the store so the switch reflects a rolled-back
    /// write instead of the value the user just tapped.
    private func enabledBinding(for identity: FaceIdentity) -> Binding<Bool> {
        Binding(
            get: { store.identities.first { $0.id == identity.id }?.isEnabled ?? true },
            set: { newValue in
                do {
                    try store.setEnabled(newValue, for: identity.id)
                    writeError = nil
                } catch {
                    writeError = error.localizedDescription
                }
            }
        )
    }

    private func delete(_ identity: FaceIdentity) {
        do {
            try store.delete(identity)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
        identityPendingDeletion = nil
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SecureCredentialManager.unlockSession(reason: "验证身份以查看已录入的面容")
                }.value
                store.reloadIfUnlocked()
            } catch {
                sessionError = error.localizedDescription
            }
            isUnlocking = false
        }
    }
}

// MARK: - Identity card

/// One enrolled person: name pill and switch on the first line, quality
/// read-out and actions on the second. Built from `SettingsGroup` and the
/// shared row tokens so it matches every other settings page.
private struct IdentityCard: View {
    let identity: FaceIdentity
    let isStale: Bool
    let canStartFlow: Bool
    @Binding var isEnabled: Bool
    let recapture: () -> Void
    let delete: () -> Void

    private var poorCount: Int {
        identity.samples.filter { $0.qualityTier == .poor }.count
    }

    private var ratedCount: Int {
        identity.samples.filter { $0.qualityTier != .unrated }.count
    }

    /// Share of samples that *aren't* in the red band, e.g. 3 low out of 18
    /// samples is 15/18 good → 83%.
    private var qualityPercentage: Int {
        let total = identity.samples.count
        guard total > 0 else { return 0 }
        return Int((Double(total - poorCount) / Double(total) * 100).rounded())
    }

    /// An enrollment saved before per-sample quality existed reports "not
    /// recorded" rather than a misleading 100%.
    private var qualityCaption: String {
        if identity.samples.isEmpty { return "未采集到样本" }
        if ratedCount == 0 { return "采集质量 • 未记录" }
        return "Capture quality • \(qualityPercentage)%"
    }

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    namePill
                    .padding(.leading, -2)
                    Spacer(minLength: 8)
                    GlanceToggle(isOn: $isEnabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(qualityCaption)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textTertiary)

                    HStack(alignment: .center, spacing: 8) {
                        QualityTickStrip(samples: identity.samples)
                        .padding(.leading, 2)
                        Spacer(minLength: 12)
                        PillActionButton(title: "重新采集", action: recapture)
                            .disabled(!canStartFlow)
                            .opacity(canStartFlow ? 1 : 0.4)
                        PillIconButton(systemImage: "trash", action: delete)
                            .help("Delete \(identity.name)")
                    }
                }
                // Dimmed rather than hidden while switched off: the person
                // is still enrolled, just not being matched against.
                .opacity(isEnabled ? 1 : 0.45)

                if isStale {
                    Text("该面容由其他识别模型采集——需重新采集后此面容才能解锁你的 Mac。")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.qualityFairColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, 12)
        }
    }

    private var namePill: some View {
        Text(identity.name)
            .font(SettingsMetrics.rowFont)
            .foregroundStyle(SettingsMetrics.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(SettingsMetrics.neutralButtonFill)
            .overlay(
                Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// One tick per stored sample, colored by its band. Reads left-to-right in
/// capture order (not sorted by score) so a run of red points at the pose
/// that actually went badly.
private struct QualityTickStrip: View {
    let samples: [FaceSample]

    var body: some View {
        HStack(spacing: SettingsMetrics.qualityTickSpacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(color(for: sample.qualityTier))
                    // maxWidth, not fixed, so more samples than a guided
                    // enrollment's 18 compress instead of overflowing.
                    .frame(maxWidth: SettingsMetrics.qualityTickWidth)
            }
        }
        .frame(width: stripWidth, height: SettingsMetrics.qualityTickHeight, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Capture quality for \(samples.count) samples")
    }

    /// Fixed rather than flexible: this strip shares a row with a `Spacer`
    /// and two buttons, and a `maxWidth` frame would negotiate against them
    /// for the slack instead of just sizing to its ticks.
    private var stripWidth: CGFloat {
        let tick = SettingsMetrics.qualityTickWidth
        let gap = SettingsMetrics.qualityTickSpacing
        let natural = CGFloat(samples.count) * (tick + gap) - gap
        return min(max(natural, 0), SettingsMetrics.qualityStripMaxWidth)
    }

    private func color(for tier: FaceSample.QualityTier) -> Color {
        switch tier {
        case .poor: return SettingsMetrics.qualityPoorColor
        case .fair: return SettingsMetrics.qualityFairColor
        case .good: return SettingsMetrics.qualityGoodColor
        case .unrated: return SettingsMetrics.qualityUnratedColor
        }
    }
}

/// Neutral capsule button matching the card's inner pills. Deliberately not
/// `SettingsPrimaryButton`: this sits next to a destructive action and
/// shouldn't read as the accent CTA.
private struct PillActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(SettingsMetrics.neutralButtonFill)
                .overlay(
                    Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The circular icon twin of `PillActionButton`, for the delete control.
private struct PillIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .frame(width: 28, height: 28)
                .background(SettingsMetrics.neutralButtonFill)
                .overlay(
                    Circle().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
