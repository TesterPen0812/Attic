import Foundation

/// Date, tags and priority on existing tasks without the shorthand (owner
/// fixes 3 and 5: the right-click menu, a row's date and tag popovers),
/// and the add bar's strip and suggestions. Every change to existing tasks
/// is one step for the selection it targets, with an Undo toast.
extension TasksPageModel {
    var dateChoices: TaskDateChoices { TaskDateChoices(parser: parser) }

    /// The shorthand's first use, done ahead of the first keystroke: the
    /// parser's words and formatters, the quick days, the tags list.
    func warmUpShorthand() {
        var sample = TaskAddBarText(text: "Pay rent tomorrow 30 Sep #home !!")
        _ = sample.chips(parser: parser, caret: nil)
        _ = sample.markShown(parser: parser, caret: 0)
        _ = sample.suggestion(parser: parser, caret: (sample.text as NSString).length, tags: cachedTags)
        _ = dateChoices.quick.map { dateChoices.detail(for: $0.day) }
    }

    /// The library's tags, most used first.
    var allTags: [String] { library.tags.counts().map(\.name) }

    func dueDay(of id: UUID) -> DueDay? { store.listedTask(withID: id)?.dueDay }

    /// A task wherever it is listed: the lists, or the Done log (round 10:
    /// Done's rows take the same edits, without changing completion).
    func listedTask(_ id: UUID) -> TaskItem? { store.listedTask(withID: id) }

    /// Some of `ids` are only in the Done log: their edits go through the
    /// listed route (`AtticLibrary.updateListedTasks`).
    func reachesDoneLog(_ ids: [UUID]) -> Bool {
        ids.contains { store.task(withID: $0) == nil && store.listedTask(withID: $0) != nil }
    }

    /// The due day of every target, or nil when they differ or have none.
    func commonDueDay(_ ids: [UUID]) -> DueDay? {
        let days = Set(ids.map { listedTask($0)?.dueDay })
        return days.count == 1 ? days.first ?? nil : nil
    }

    /// Date ▸ in the menu, a row's date popover: the targets' due day set
    /// (or removed) as one step, with an Undo toast.
    @discardableResult
    func setDueDay(_ day: DueDay?, for ids: [UUID]) -> CommandOutcome {
        let live = ids.filter { listedTask($0) != nil }
        guard !live.isEmpty else { return ids.isEmpty ? .applied : .failed(.taskGone) }
        guard live.contains(where: { listedTask($0)?.dueDay != day }) else { return .applied }
        let outcome = reachesDoneLog(live)
            ? library.updateListedTasks(live, dueDay: .some(day))
            : library.updateTaskFields(live, dueDay: .some(day))
        if reachesDoneLogAfterEdit(live) { reloadDoneLogAfterEdit() }
        guard outcome.isApplied else { return outcome }
        let message: String
        if let day {
            let text = TaskRowPresentation.due(day, today: dateChoices.today, calendar: services.calendar(), locale: services.locale).text
            message = live.count == 1 ? String(localized: "Due \(text)") : String(localized: "\(live.count) tasks due \(text)")
        } else {
            message = live.count == 1 ? String(localized: "Date removed") : String(localized: "Dates removed from \(live.count) tasks")
        }
        showToast(message)
        return outcome
    }

    /// How many of the targets have `tag`: all (ticked), some (mixed), none.
    func tagState(_ tag: String, for ids: [UUID]) -> AtticCheckState {
        let tasks = ids.compactMap { listedTask($0) }
        guard !tasks.isEmpty else { return .off }
        let having = tasks.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.count
        return having == 0 ? .off : (having == tasks.count ? .on : .mixed)
    }

    /// A click on a tag in the tag list (review 17's bulk rule): ticked
    /// (every target has it) removes it from all; empty or mixed adds it to
    /// all. One step, with an Undo toast.
    @discardableResult
    func toggleTag(_ tag: String, for ids: [UUID]) -> CommandOutcome {
        guard let tag = AtticTag.normalize(tag) else { return .applied }
        let live = ids.filter { listedTask($0) != nil }
        guard !live.isEmpty else { return ids.isEmpty ? .applied : .failed(.taskGone) }
        let removing = tagState(tag, for: live) == .on
        let outcome = reachesDoneLog(live)
            ? library.updateListedTasks(live, addingTag: removing ? nil : tag, removingTag: removing ? tag : nil)
            : library.updateTaskFields(live, addingTag: removing ? nil : tag, removingTag: removing ? tag : nil)
        if reachesDoneLogAfterEdit(live) { reloadDoneLogAfterEdit() }
        guard outcome.isApplied else { return outcome }
        showToast(removing ? String(localized: "Removed #\(tag)") : String(localized: "Tagged #\(tag)"))
        return outcome
    }

    /// The tags the tag list shows for these targets: theirs first, then
    /// the rest of the library's.
    func tagChoices(for ids: [UUID]) -> [String] {
        let own = AtticTag.normalizedSet(ids.compactMap { listedTask($0) }.flatMap(\.tags))
        let rest = allTags.filter { tag in !own.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        return own + rest
    }

    // MARK: - The add bar's strip and suggestions

    /// The add bar's field is about to replace `range` with `replacement`
    /// (typing, paste, an edit the field makes): one step of the draft's
    /// history, the pieces moved along.
    func addBarEdited(_ range: NSRange, replacement: String) {
        let state = addBarState
        state.history.willEdit(state.text, selection: state.currentSelection, range: range, replacement: replacement)
        state.text.edited(range, replacement: replacement)
        state.hiddenSuggestion = nil
        state.highlighted = 0
    }

    /// The add bar's insertion point moved (every edit reports it): pieces
    /// it has left are finished (drawn as chips), and a finished date or
    /// priority typed after a pick replaces the pick (round 7, R1: never a
    /// word still being typed at the caret).
    func addBarCaretMoved(_ caret: Int) {
        if addBarState.caret != caret { addBarState.caret = caret }
        // Assign only a change: every assignment redraws the bar.
        var shown = addBar
        let marked = shown.markShown(parser: parser, caret: caret)
        let replaced = shown.typedReplacesPicks(parser: parser, caret: caret)
        if marked || replaced { addBar = shown }
    }

    /// The day's words as a row shows them ("Tomorrow", "Tue", "30 Sep").
    func dueText(_ day: DueDay) -> String {
        TaskRowPresentation.due(day, today: dateChoices.today, calendar: services.calendar(), locale: services.locale).text
    }

    /// A taken suggestion is one undo step, with its value: the
    /// state before it is the checkpoint, its text edits are not steps of
    /// their own, and the pin that follows belongs to the same step.
    @discardableResult
    private func programmaticEdit(_ editor: AtticTokenFieldEditor, _ edit: () -> Bool) -> Bool {
        let selection = editor.selection ?? addBarState.currentSelection
        addBarState.history.checkpoint(addBar, selection: selection)
        addBarState.history.isSuspended = true
        defer { addBarState.history.isSuspended = false }
        return edit()
    }

    // MARK: The strip's values (owner item 18)

    /// Which of the strip's buttons.
    enum ComposerField: Equatable {
        case date, tags, priority
    }

    /// A pick or a clear on the strip: one undo step. Typed pieces it
    /// replaces leave the text (with a space beside each) in the same step;
    /// the text is otherwise the person's own. Returns whether anything
    /// changed.
    @discardableResult
    private func composerChange(_ editor: AtticTokenFieldEditor, removing pieces: [NSRange],
                                _ change: (inout TaskAddBarText.Picks) -> Void) -> Bool {
        var picks = addBar.picked
        change(&picks)
        guard !pieces.isEmpty || picks != addBar.picked else { return false }
        let selection = editor.selection ?? addBarState.currentSelection
        addBarState.history.checkpoint(addBar, selection: selection)
        if !pieces.isEmpty {
            let edits = addBar.removals(of: pieces)
            let caret = TaskAddBarText.caret(selection?.location ?? (addBar.text as NSString).length, after: edits)
            addBarState.history.isSuspended = true
            if !editor.replace(edits, caretAfter: caret) {
                var text = addBar
                text.apply(edits)
                addBar = text
                addBarCaret = caret
            }
            addBarState.history.isSuspended = false
        }
        var text = addBar
        text.picked = picks
        addBar = text
        return true
    }

    /// A day picked from the strip: it sits on the Date button; a typed
    /// date leaves the text.
    func pickDate(_ day: DueDay, editor: AtticTokenFieldEditor) {
        composerChange(editor, removing: addBar.ranges(of: .date, parser: parser)) { $0.day = day }
    }

    /// Priority from the strip; No Priority clears it (typed marks go too).
    func pickPriority(_ priority: TaskPriority, editor: AtticTokenFieldEditor) {
        composerChange(editor, removing: addBar.ranges(of: .priority, parser: parser)) {
            $0.priority = priority == .none ? nil : priority
        }
    }

    /// The strip's tag list ticks and unticks: a tag the task would get
    /// (typed or picked) goes, typed words included; another is added.
    func toggleComposerTag(_ tag: String, editor: AtticTokenFieldEditor) {
        guard let tag = AtticTag.normalize(tag) else { return }
        let has = addBar.parts(parser: parser).tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        if has {
            composerChange(editor, removing: addBar.ranges(of: .tag, tag: tag, parser: parser)) { picks in
                picks.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            }
        } else {
            composerChange(editor, removing: []) { $0.tags.append(tag) }
        }
    }

    /// × on a strip button: the new task gets no date (tags, priority);
    /// typed pieces of that kind leave the text too.
    func clearComposer(_ field: ComposerField, editor: AtticTokenFieldEditor) {
        switch field {
        case .date: composerChange(editor, removing: addBar.ranges(of: .date, parser: parser)) { $0.day = nil }
        case .priority: composerChange(editor, removing: addBar.ranges(of: .priority, parser: parser)) { $0.priority = nil }
        case .tags: composerChange(editor, removing: addBar.ranges(of: .tag, parser: parser)) { $0.tags = [] }
        }
    }

    /// The tag list's state for the new task, and its tags: the task's
    /// first (typed or picked), then the library's.
    func composerTagState(_ tag: String) -> AtticCheckState {
        addBar.parts(parser: parser).tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } ? .on : .off
    }

    var composerTagChoices: [String] {
        let own = addBar.parts(parser: parser).tags
        return own + allTags.filter { tag in !own.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
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
        guard programmaticEdit(editor, { editor.replace([(range, string)], caretAfter: caretAfter) }) else { return }
        guard let value else { return }
        var text = addBar
        text.pin(NSRange(location: range.location, length: (words as NSString).length), value: value)
        addBar = text
    }
}
