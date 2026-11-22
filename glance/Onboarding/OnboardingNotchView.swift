//
//  OnboardingNotchView.swift
//  glance
//
//  Routes `controller.step` to its screen and applies the scroll-with-blur transition
//  between them: Next travels upward, Back is the mirror, travelling downward.
//

import SwiftUI

struct OnboardingNotchView: View {
    let controller: OnboardingController
    /// v2: true when hosted in the standalone window (not the old notch panel).
    /// Uses window-specific sizing and reports size changes back so the window hugs content.
    var windowMode: Bool = false
    var onSizeChange: ((CGSize) -> Void)? = nil

    private var contentSize: CGSize {
        windowMode ? OnboardingMetrics.windowSize(for: controller.step) : controller.panelSize
    }

    var body: some View {
        ZStack {
            switch controller.step {
            case .intro:
                IntroStepView(controller: controller)
            case .permissions:
                PermissionsStepView(controller: controller)
            case .securityNotice:
                SecurityNoticeStepView(controller: controller)
            case .preSetup:
                PreSetupStepView(controller: controller)
            case .selectCamera:
                SelectCameraStepView(controller: controller)
            case .enroll:
                EnrollStepView(controller: controller)
            case .name:
                NameStepView(controller: controller)
            case .password:
                PasswordStepView(controller: controller)
            case .complete:
                CompleteStepView()
            }
        }
        .id(controller.step)
        .frame(width: contentSize.width, height: contentSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear { onSizeChange?(contentSize) }
        .onChange(of: controller.step) { _, _ in onSizeChange?(contentSize) }
        .overlay(alignment: .topTrailing) {
            if controller.step != .complete {
                Button {
                    controller.teardown()
                    OnboardingWindowController.shared.dismissOnboarding()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("稍后再说（可从菜单栏「设置」继续）")
            }
        }
        .transition(stepTransition)
    }

    private var stepTransition: AnyTransition {
        let travel = contentSize.height
        let insertionOffset: CGFloat = controller.navDirection == .forward ? travel : -travel
        let removalOffset: CGFloat = controller.navDirection == .forward ? -travel : travel
        return .asymmetric(
            insertion: .modifier(
                active: OffsetBlurOpacity(offset: insertionOffset, blur: 12, opacity: 0),
                identity: OffsetBlurOpacity(offset: 0, blur: 0, opacity: 1)
            ),
            removal: .modifier(
                active: OffsetBlurOpacity(offset: removalOffset, blur: 12, opacity: 0),
                identity: OffsetBlurOpacity(offset: 0, blur: 0, opacity: 1)
            )
        )
    }
}

/// Backing modifier for the scroll+blur transition — offsets, blurs, and fades at once
/// so content reads as scrolling past with a dissolve rather than a hard cut.
private struct OffsetBlurOpacity: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}
