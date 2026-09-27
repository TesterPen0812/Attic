import Foundation

/// Date, tags and priority on existing tasks without the shorthand (owner
/// fixes 3 and 5: the right-click menu, a row's date and tag popovers),
/// and the add bar's strip and suggestions. Every change to existing tasks
/// is one step for the selection it targets, with an Undo toast.
extension TasksPageModel {
    var dateChoices: TaskDateChoices { TaskDateChoices(parser: parser) }

    /// The library's tags, most used first.
    var allTags: [String] { library.tags.counts().map(\.name) }

    func dueDay(of id: UUID) -> DueDay? { store.task(withID: id)?.dueDay }

    /// The due day of every target, or nil when they differ or have none.
    func commonDueDay(_ ids: [UUID]) -> DueDay? {
        let days = Set(ids.map { store.task(withID: $0)?.dueDay })
        return days.count == 1 ? days.first ?? nil : nil
    }

    /// Date ▸ in the menu, a row's date popover: the targets' due day set
    /// (or removed) as one step, with an Undo toast.
    func setDueDay(_ day: DueDay?, for ids: [UUID]) {
        let live = ids.filter { store.task(withID: $0) != nil }
        guard !live.isEmpty, live.contains(where: { store.task(withID: $0)?.dueDay != day }) else { return }
        guard library.updateTaskFields(live, dueDay: .some(day)).isApplied else { return }
        let message: String
        if let day {
            let text = TaskRowPresentation.due(day, today: dateChoices.today, calendar: services.calendar(), locale: services.locale).text
            message = live.count == 1 ? String(localized: "Due \(text)") : String(localized: "\(live.count) tasks due \(text)")
        } else {
            message = live.count == 1 ? String(localized: "Date removed") : String(localized: "Dates removed from \(live.count) tasks")
        }
        showToast(message)
    }

    /// How many of the targets have `tag`: all (ticked), some (mixed), none.
    func tagState(_ tag: String, for ids: [UUID]) -> AtticCheckState {
        let tasks = ids.compactMap { store.task(withID: $0) }
        guard !tasks.isEmpty else { return .off }
        let having = tasks.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.count
        return having == 0 ? .off : (having == tasks.count ? .on : .mixed)
    }

    /// A click on a tag in the tag list (review 17's bulk rule): ticked
    /// (every target has it) removes it from all; empty or mixed adds it to
    /// all. One step, with an Undo toast.
    func toggleTag(_ tag: String, for ids: [UUID]) {
        guard let tag = AtticTag.normalize(tag) else { return }
        let live = ids.filter { store.task(withID: $0) != nil }
        guard !live.isEmpty else { return }
        let removing = tagState(tag, for: live) == .on
        guard library.updateTaskFields(live, addingTag: removing ? nil : tag, removingTag: removing ? tag : nil).isApplied else { return }
        showToast(removing ? String(localized: "Removed #\(tag)") : String(localized: "Tagged #\(tag)"))
    }

    /// The tags the tag list shows for these targets: theirs first, then
    /// the rest of the library's.
    func tagChoices(for ids: [UUID]) -> [String] {
        let own = AtticTag.normalizedSet(ids.compactMap { store.task(withID: $0) }.flatMap(\.tags))
        let rest = allTags.filter { tag in !own.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        return own + rest
    }

    // MARK: - The add bar's strip and suggestions

    /// A day picked from the strip: into the draft as its words, holding
    /// the exact day, in place of a date already there (review 16).
    func pickDate(_ day: DueDay, editor: AtticTokenFieldEditor) {
        insertPiece(dateChoices.shorthand(for: day), value: .dueDay(day), kind: .date, editor: editor)
    }

    /// Priority from the strip: "!" or "!!" (or none: the typed one goes).
    func pickPriority(_ priority: TaskPriority, editor: AtticTokenFieldEditor) {
        let existing = addBar.range(of: .priority, parser: parser)
        guard let words = priority.shorthand else {
            guard let existing else { return }
            // Remove the mark and one space beside it.
            let ns = addBar.text as NSString
            var range = existing
            if NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range)) == 32 { range.length += 1 }
            else if range.location > 0, ns.character(at: range.location - 1) == 32 { range.location -= 1; range.length += 1 }
            editor.replace([(range, "")])
            return
        }
        insertPiece(words, value: .priority(priority), kind: .priority, editor: editor)
    }

    private func insertPiece(_ words: String, value: ParsedTaskToken.Value, kind: TaskAddBarText.PieceKind, editor: AtticTokenFieldEditor) {
        let existing = addBar.range(of: kind, parser: parser)
        let plan = addBar.insertion(of: words, replacing: existing, caret: editor.caret ?? addBarCaret)
        let caretAfter = plan.range.location + (plan.string as NSString).length
        guard editor.replace([(plan.range, plan.string)], caretAfter: caretAfter) else { return }
        var text = addBar
        text.pin(plan.piece, value: value)
        addBar = text
    }

    /// The strip's Tag: types "#" where the caret is (a space first when
    /// it follows a word), which opens the tag suggestions.
    func startTag(editor: AtticTokenFieldEditor) {
        let ns = addBar.text as NSString
        let caret = min(editor.caret ?? ns.length, ns.length)
        let needsSpace = caret > 0 && ns.character(at: caret - 1) != 32
        let string = needsSpace ? " #" : "#"
        editor.replace([(NSRange(location: caret, length: 0), string)], caretAfter: caret + (string as NSString).length)
        editor.focus()
    }

    /// Takes a suggestion: a tag ("#home ") or a date's words, pinned to
    /// the day shown, followed by a space so the chip forms.
    func accept(_ suggestion: TaskAddBarText.Suggestion, choice index: Int, editor: AtticTokenFieldEditor) {
        switch suggestion {
        case let .tags(range, _, matches, create):
            let name = index < matches.count ? matches[index] : create
            guard let name else { return }
            replaceWord(range, with: "#" + name, value: nil, editor: editor)
        case let .date(range, words, _, day):
            replaceWord(range, with: words, value: .dueDay(day), editor: editor)
        }
    }

    private func replaceWord(_ range: NSRange, with words: String, value: ParsedTaskToken.Value?, editor: AtticTokenFieldEditor) {
        let ns = addBar.text as NSString
        let hasSpaceAfter = NSMaxRange(range) < ns.length && ns.character(at: NSMaxRange(range)) == 32
        let string = words + (hasSpaceAfter ? "" : " ")
        let caretAfter = range.location + (words as NSString).length + 1
        guard editor.replace([(range, string)], caretAfter: caretAfter) else { return }
        guard let value else { return }
        var text = addBar
        text.pin(NSRange(location: range.location, length: (words as NSString).length), value: value)
        addBar = text
    }
}
