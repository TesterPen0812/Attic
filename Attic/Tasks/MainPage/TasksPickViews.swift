import SwiftUI

// Pick your Now (council D2, `states-d2.png`) and Find across every list
// (`states-d3.png` panel 4, in the one-row header). Values from
// `final/council-lib.js` (`dueLine`, `pickFromLater`, `sectionLabel`,
// `dock`, `dockBtn`, `states-d3.html`'s field).

/// The Due line above Now: only when a task outside Now is due.
struct TasksDueLineView: View {
    let line: TasksDueLine
    /// The due date as the rows say it ("Late 23 Oct", "Today").
    let dateText: (DueDay) -> String
    let isOverdue: (DueDay) -> Bool
    let onPick: () -> Void

    var body: some View {
        switch line {
        case .none:
            EmptyView()
        case let .one(_, title, due):
            content(height: 48) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(dateText(due)).fontWeight(isOverdue(due) ? .semibold : .regular)
                            .foregroundStyle(TasksCardInk.red)
                        Text("· waiting in Later").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11)).lineLimit(1)
                }
            }
        case let .several(count):
            content(height: 34) {
                Text("\(count) due in Later").font(.system(size: 13)).lineLimit(1)
            }
        }
    }

    private func content<Label: View>(height: CGFloat, @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(TasksCardInk.red)
                .frame(width: 27, alignment: .leading).padding(.leading, 11)
            label()
            Spacer(minLength: 8)
            Button(action: onPick) {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("Pick").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(TasksCardInk.accent))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .accessibilityIdentifier("tasks-due-line-pick")
        }
        .frame(height: height - 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(TasksCardInk.red.opacity(0.10)))
        .padding(.vertical, 2)
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tasks-due-line")
    }
}

/// "Pick from Later · N waiting ›", the last row of Now.
struct TasksPickFromLaterRow: View {
    let waiting: Int
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 0) {
                TasksPickTarget(picked: false).padding(.leading, 6).padding(.trailing, 5)
                Text("Pick from Later").font(.system(size: 13, weight: .medium)).foregroundStyle(TasksCardInk.accent)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("\(waiting) waiting")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .padding(.trailing, 10)
            }
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 0, trailing: 8))
        .help(String(localized: "Pick from Later (P)"))
        .accessibilityIdentifier("tasks-pick-from-later")
    }
}

/// Pick mode's ring: a ＋ target, or ✓ once picked (18 pt, 24 pt hit).
struct TasksPickTarget: View {
    let picked: Bool

    var body: some View {
        ZStack {
            if picked {
                Circle().fill(TasksCardInk.accent)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().strokeBorder(TasksCardInk.accent, style: StrokeStyle(lineWidth: 1.5, dash: [2.2, 2.2]))
                Image(systemName: "plus").font(.system(size: 8, weight: .bold)).foregroundStyle(TasksCardInk.accent)
            }
        }
        .frame(width: 18, height: 18)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .accessibilityLabel(picked ? String(localized: "Picked") : String(localized: "Pick"))
    }
}

/// DUE, LATER, and Find's NOW · 2 headers.
struct TasksSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 9).padding(.top, 7)
            .frame(height: 24, alignment: .top)
            .padding(.horizontal, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The add bar's place in pick mode: "N picked for Now · esc · Done".
struct TasksPickDock: View {
    let count: Int
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TasksPickTarget(picked: count > 0).scaleEffect(14 / 18).frame(width: 16)
            (Text("\(count) picked").fontWeight(.semibold) + Text(" for Now").foregroundColor(.secondary))
                .font(.system(size: 12.5))
            Spacer(minLength: 8)
            Text("esc").font(.system(size: 11)).foregroundStyle(.tertiary)
            Button(action: onDone) {
                Text("Done").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(TasksCardInk.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityIdentifier("tasks-pick-done")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks-pick-dock")
    }
}

/// Find in the header's place of the tabs: the field, the scope chip and ✕.
struct TasksFindField: View {
    @Binding var query: String
    let scope: TasksFindSession.Scope
    let onScope: (TasksFindSession.Scope) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(String(localized: "Find in all lists"), text: $query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .accessibilityIdentifier("tasks-find-field")
            Button { onScope(scope == .allLists ? .thisList : .allLists) } label: {
                Text(scope == .allLists ? String(localized: "All lists") : String(localized: "This list"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Search all lists or only this one"))
            .accessibilityIdentifier("tasks-find-scope")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close Find"))
            .accessibilityIdentifier("tasks-find-close")
        }
        .padding(.leading, 11).padding(.trailing, 4)
        .frame(height: 28)
        .onAppear { focused = true }
    }
}
