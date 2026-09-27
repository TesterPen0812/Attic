import SwiftUI

/// Settings › Compare (temporary): one switch per suggested change that
/// departs from an owner decision (`AtticReviewVariant`), each with what on
/// and off do. On is the suggestion; off is exactly the design decided.
/// Flipping a switch changes the panel and Settings at once. The page goes
/// when the owner has picked every one.
struct CompareSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(section: .compare) {
            ForEach(AtticReviewVariant.allCases) { variant in
                SettingsGroup(footnote: variant.summary, identifier: "\(variant.identifier)-group") {
                    AtticSwitchRow(
                        title: variant.title,
                        isOn: binding(variant),
                        identifier: variant.identifier
                    )
                    .help(variant.summary)
                }
            }
        }
    }

    private func binding(_ variant: AtticReviewVariant) -> Binding<Bool> {
        Binding(
            get: { settings.reviewVariants.isOn(variant) },
            set: { settings.reviewVariants.set(variant, $0) }
        )
    }
}
