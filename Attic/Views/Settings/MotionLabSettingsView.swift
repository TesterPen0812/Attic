import AppKit
import SwiftUI

/// Settings › General › Motion Lab (preview builds only, owner 2026-09-30:
/// "I'm not really a fan of fading ones, I much more prefer the
/// bounciness, even if it's slight"). The owner feels the motion live in
/// the panel and picks it: a feel (Calm, Subtle, Lively, Playful), the Appear and
/// Leave styles, and fine-tuning sliders. Every change applies at once
/// (`AppSettings.motionTuning` is `AtticMotionTuning.current` and part of
/// the design context), and persists in the preview's own defaults.
/// "Copy values" puts the values on the clipboard, as text and as Swift,
/// to bake into `AtticMotionTuning`. Shown only where
/// `AtticMotionLab.isAvailable` (never under the release identity).
/// The lab's words are not localized: it is a preview-only tool.
struct MotionLabSettingsGroup: View {
    @ObservedObject var settings: AppSettings

    @State private var showsFineTuning = false
    @State private var copied = false
    /// How lists meet the floating controls (owner, 2026-10-01): the
    /// system's soft scroll edge, or round 13's clean cut, to feel both.
    @ObservedObject private var scrollEdges = AtticScrollEdgeLab.shared

    var body: some View {
        SettingsGroup(
            title: "Motion Lab",
            footnote: "Preview builds only. Each change applies at once: open the panel and try it. Reduced animations and Reduce Motion ignore the feel, and changing Animations above puts the feel back to Lively or Subtle.",
            identifier: "settings-motion-lab"
        ) {
            AtticSegmentedRow(
                title: "Feel",
                choices: AtticMotionFeel.allCases.map { ($0, $0.title) },
                selection: Binding(get: { settings.motionFeel }, set: { settings.chooseMotionFeel($0) }),
                identifier: "setting-motion-feel"
            )
            AtticGroupDivider()
            AtticPopUpRow(
                label: "Appear",
                choices: AtticMotionStyle.allCases.map { ($0, $0 == .spring ? "Spring in with a small pop" : "Fade") },
                selection: $settings.motionTuning.appear,
                identifier: "setting-motion-appear"
            )
            AtticGroupDivider()
            AtticPopUpRow(
                label: "Leave",
                choices: AtticMotionStyle.allCases.map { ($0, $0 == .spring ? "Tuck away with a quick spring" : "Fade") },
                selection: $settings.motionTuning.leave,
                identifier: "setting-motion-leave"
            )
            AtticGroupDivider()
            // A strict preview only: the Motion Lab's broader policy (a
            // launch argument) does not show it.
            if scrollEdges.offersChoice {
                AtticSegmentedRow(
                    title: "Scroll edges",
                    choices: AtticScrollEdgeStyle.allCases.map { ($0, $0.title) },
                    selection: $scrollEdges.style,
                    identifier: "setting-scroll-edges"
                )
                AtticGroupDivider()
            }
            AtticSwitchRow(
                title: "Native pop-overs spring in (experimental)",
                isOn: $settings.motionTuning.popsNativePopovers,
                identifier: "setting-motion-native-popovers"
            )
            AtticGroupDivider()
            AtticActionRow(
                title: "Fine-tune",
                value: summary,
                actionTitle: showsFineTuning ? "Hide" : "Show",
                actionIdentifier: "setting-motion-fine-tune"
            ) {
                showsFineTuning.toggle()
            }
            if showsFineTuning {
                sliders
            }
            AtticGroupDivider()
            AtticActionRow(
                title: copied ? "Copied to the clipboard" : "Values",
                value: settings.motionTuning == settings.motionFeel.tuning
                    ? settings.motionFeel.title : "\(settings.motionFeel.title), edited",
                actionTitle: "Copy values",
                actionIdentifier: "setting-motion-copy"
            ) {
                copy()
            }
            if settings.motionTuning != settings.motionFeel.tuning {
                AtticGroupDivider()
                AtticActionRow(
                    title: "Undo the edits",
                    actionTitle: "Reset to \(settings.motionFeel.title)",
                    actionIdentifier: "setting-motion-reset"
                ) {
                    settings.chooseMotionFeel(settings.motionFeel)
                }
            }
        }
    }

    @ViewBuilder
    private var sliders: some View {
        let range = AtticMotionTuning.responseRange
        AtticGroupDivider()
        slider("Navigation response", seconds($settings.motionTuning.navigationResponse), range, "setting-motion-nav-response")
        AtticGroupDivider()
        slider("Navigation bounce", plain($settings.motionTuning.navigationBounce), AtticMotionTuning.bounceRange, "setting-motion-nav-bounce")
        AtticGroupDivider()
        slider("Appear response", seconds($settings.motionTuning.appearResponse), range, "setting-motion-appear-response")
        AtticGroupDivider()
        slider("Appear bounce", plain($settings.motionTuning.appearBounce), AtticMotionTuning.bounceRange, "setting-motion-appear-bounce")
        AtticGroupDivider()
        slider("Appear scale", plain($settings.motionTuning.appearScale), AtticMotionTuning.scaleRange, "setting-motion-appear-scale")
        AtticGroupDivider()
        slider("Leave response", seconds($settings.motionTuning.leaveResponse), AtticMotionTuning.leaveRange, "setting-motion-leave-response")
    }

    private typealias Labelled = (binding: Binding<Double>, text: String)

    private func seconds(_ binding: Binding<Double>) -> Labelled {
        (binding, String(format: "%.2f s", binding.wrappedValue))
    }

    private func plain(_ binding: Binding<Double>) -> Labelled {
        (binding, String(format: "%.2f", binding.wrappedValue))
    }

    private func slider(_ label: String, _ value: Labelled, _ range: ClosedRange<Double>, _ identifier: String) -> some View {
        AtticSliderRow(label: label, valueText: value.text, value: value.binding, range: range, step: 0.01,
                       identifier: identifier)
    }

    /// The fine-tuning at a glance.
    private var summary: String {
        let tuning = settings.motionTuning
        return String(format: "Navigation %.2f s / %.2f · appear %.2f s / %.2f from %.2f · leave %.2f s",
                      tuning.navigationResponse, tuning.navigationBounce, tuning.appearResponse,
                      tuning.appearBounce, tuning.appearScale, tuning.leaveResponse)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(settings.motionTuning.copyText(feel: settings.motionFeel), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
