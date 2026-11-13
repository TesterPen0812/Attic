import Foundation
import CryptoKit

extension AgentActions {
    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static func definition(_ name: String, _ description: String,
                                   _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": schema(properties, required: required)]
    }

    static let extraDefinitions: [[String: Any]] = {
        let string: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number"]
        let position: [String: Any] = ["x": number, "y": number]
        let frame = position.merging(["width": number, "height": number]) { _, new in new }
        let style: [String: Any] = [
            "colour": ["type": "string", "enum": DrawColour.allCases.map(\.rawValue)],
            "size": ["type": "string", "enum": DrawSize.allCases.map(\.rawValue)],
            "corners": ["type": "string", "enum": DrawCorners.allCases.map(\.rawValue)]
        ]
        let canvas: [String: Any] = ["canvas_id": string,
                                     "canvas_name": ["type": "string", "description": "Canvas title; omit both canvas selectors when only one canvas exists."]]
        let eventFields: [String: Any] = [
            "title": string, "start": string, "end": string, "calendar_id": string,
            "time_zone": string, "all_day": ["type": "boolean"], "notes": string
        ]
        let span: [String: Any] = ["start": string, "end": string]
        var createTaskFields = (AgentTaskTools.taskDefinitions.first { $0["name"] as? String == "create_task" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        createTaskFields["parent_query"] = string
        var updateTaskFields = (AgentTaskTools.taskDefinitions.first { $0["name"] as? String == "update_task" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        updateTaskFields["query"] = string
        return [
            definition("search_items", "Find tasks, notes and canvases using loose wording, typos and partial titles. Returns names, IDs and state.",
                       ["query": string, "pages": ["type": "array", "items": ["type": "string", "enum": ["tasks", "notes", "draw"]]],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100]], required: ["query"]),
            definition("create_tasks", "Create up to 50 tasks or subtasks in one call. Every result includes saved state or its own error; earlier successes remain undoable.",
                       ["tasks": ["type": "array", "minItems": 1, "maxItems": 50,
                                  "items": schema(createTaskFields, required: ["title"])]], required: ["tasks"]),
            definition("update_tasks", "Update up to 50 tasks in one call using id or a unique loose-name query for each. Returns changed task states and explicit individual failures.",
                       ["updates": ["type": "array", "minItems": 1, "maxItems": 50,
                                    "items": schema(updateTaskFields)]], required: ["updates"]),
            definition("open_page", "Open an Attic page only while its owner is watching.",
                       ["page": ["type": "string", "enum": AgentPage.allCases.map(\.rawValue)]], required: ["page"]),
            definition("calendar_search", "Find Calendar occurrences by loose wording. Defaults to the previous 7 through next 30 days; use start/end to choose a window.",
                       span.merging(["query": string]) { _, new in new }, required: ["query"]),
            definition("calendar_read", "Read one Calendar occurrence by its occurrence_id from search results.",
                       ["occurrence_id": string], required: ["occurrence_id"]),
            definition("calendar_list_calendars", "List writable calendars with titles and stable calendar_id values.", [:]),
            definition("calendar_create", "Create an event; with one writable calendar it is selected automatically. End defaults to one hour after start (one day for all-day events). Dates use ISO-8601 with UTC offset.",
                       eventFields, required: ["title", "start"]),
            definition("calendar_update", "Change selected fields of an Attic-owned event by id or occurrence_id. Unspecified fields keep their existing values.",
                       eventFields.merging(["id": string, "occurrence_id": string]) { _, new in new }),
            definition("calendar_delete", "Delete an Attic-owned event by id or occurrence_id; the owner approves first.",
                       ["id": string, "occurrence_id": string]),
            definition("draw_list_canvases", "List live Draw canvases and their IDs.", [:]),
            definition("draw_read_canvas", "Read a canvas's visible objects (up to 100), their IDs, text, types and frames. Image bytes and full stroke samples are omitted. Use object IDs when editing.", canvas),
            definition("draw_edit_text", "Replace the text in an existing Draw text box. Pass its object_id and expected_text from draw_read_canvas; an intervening edit is refused. Undo restores the previous text.",
                       canvas.merging(["object_id": string, "expected_text": string, "text": string]) { _, new in new },
                       required: ["object_id", "expected_text", "text"]),
            definition("draw_move_object", "Move an existing Draw object to absolute x/y coordinates in points. Supply its current expected_x/expected_y from draw_read_canvas to protect intervening owner edits. Undo restores the old position.",
                       canvas.merging(["object_id": string, "x": number, "y": number,
                                       "expected_x": number, "expected_y": number]) { _, new in new },
                       required: ["object_id", "x", "y", "expected_x", "expected_y"]),
            definition("draw_rename_canvas", "Rename an existing saved Draw canvas. Supply expected_name from draw_list_canvases so a newer owner rename cannot be overwritten. Undo restores the name.",
                       canvas.merging(["name": string, "expected_name": string]) { _, new in new },
                       required: ["name", "expected_name"]),
            definition("draw_delete_canvas", "Move a saved Draw canvas to Recently Deleted. Requires the owner's approval and is undoable; permanent deletion is unavailable.",
                       canvas),
            definition("draw_create_canvas", "Create and save a Draw canvas, including an empty one. Supply an optional name; the canvas can be undone.",
                       ["name": string]),
            definition("draw_duplicate_canvas", "Duplicate a saved canvas and all its visible objects into a new canvas. The new canvas can be undone.",
                       canvas.merging(["name": string]) { _, new in new }),
            definition("draw_delete_object", "Remove a Draw object from its canvas. Requires owner approval. Supply object_id and object_token from draw_read_canvas; an intervening edit cancels deletion. Undo restores the object.",
                       canvas.merging(["object_id": string, "object_token": string]) { _, new in new },
                       required: ["object_id", "object_token"]),
            definition("draw_restyle_object", "Change an existing Draw object's colour, size or corners. Use its current object_token from draw_read_canvas to avoid overwriting intervening edits.",
                       canvas.merging(style.merging(["object_id": string, "object_token": string]) { _, new in new }) { _, new in new },
                       required: ["object_id", "object_token"]),
            definition("draw_resize_object", "Resize a Draw object from its top-left corner in points using the same geometry transformations as the page. Images keep their proportions. Use object_token from draw_read_canvas.",
                       canvas.merging(["object_id": string, "object_token": string, "width": number, "height": number]) { _, new in new },
                       required: ["object_id", "object_token", "width", "height"]),
            definition("draw_add_text", "Add a text box to an existing Draw canvas; geometry is in points.",
                       canvas.merging(frame.merging(style) { _, new in new }.merging(["text": string]) { _, new in new }) { _, new in new },
                       required: ["text", "x", "y"]),
            definition("draw_add_shape", "Add a rectangle, ellipse, line or arrow to Draw.",
                       canvas.merging(frame.merging(style) { _, new in new }.merging([
                        "shape": ["type": "string", "enum": DrawShape.allCases.map(\.rawValue)]
                       ]) { _, new in new }) { _, new in new },
                       required: ["shape", "x", "y", "width", "height"]),
            definition("draw_add_strokes", "Add a freehand stroke with absolute point coordinates.",
                       canvas.merging(style.merging(["points": [
                        "type": "array", "minItems": 2, "maxItems": 1000,
                        "items": schema(position, required: ["x", "y"])
                       ]]) { _, new in new }) { _, new in new },
                       required: ["points"])
        ]
    }()

    private static func isoDate(_ value: Any?, _ name: String) throws -> Date {
        guard let raw = value as? String else { throw AgentActionsError.invalid("\(name) must be ISO-8601 with a timezone.") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else {
            throw AgentActionsError.invalid("\(name) must be ISO-8601 with a timezone.")
        }
        return date
    }

    private static func uuid(_ value: Any?, _ name: String) throws -> UUID {
        guard let raw = value as? String, let id = UUID(uuidString: raw) else {
            throw AgentActionsError.invalid("\(name) must be a UUID.")
        }
        return id
    }

    private static func number(_ value: Any?, _ name: String, fallback: Double? = nil) throws -> Double {
        if value == nil, let fallback { return fallback }
        guard let value = value as? NSNumber, value.doubleValue.isFinite else {
            throw AgentActionsError.invalid("\(name) must be a finite number.")
        }
        return value.doubleValue
    }

    private static func calendarRow(_ event: CalendarEvent) -> [String: Any] {
        ["occurrence_id": event.id, "title": event.title,
         "start": ISO8601DateFormatter().string(from: event.start),
         "end": ISO8601DateFormatter().string(from: event.end),
         "all_day": event.isAllDay, "calendar": event.calendarTitle,
         "location": event.location ?? ""]
    }

    private static func calendarTarget(_ event: CalendarEvent) -> AgentTarget {
        AgentTarget(page: .calendar, itemID: nil, title: event.title, externalID: event.id)
    }

    /// Resolve owned occurrences and writable calendars before an approval is
    /// shown. A stored draft protects the owner against edits made while the
    /// prompt is waiting. No EventKit write happens during preparation.
    func preparedCalendarArguments(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard ["calendar_create", "calendar_update", "calendar_delete"].contains(name) else { return arguments }
        guard let writer = calendarWriter else { throw AgentActionsError.invalid("Calendar editing is unavailable.") }
        var args = arguments
        if name == "calendar_update" || name == "calendar_delete" {
            let owned: CalendarOwnedEvent
            if let occurrence = args["occurrence_id"] as? String {
                guard let found = try await writer.ownedEvent(matching: occurrence) else {
                    throw AgentActionsError.invalid("That occurrence is not an Attic-owned editable event. Use calendar_search to find an owned event.")
                }
                owned = found
                if let rawID = args["id"] as? String, rawID != owned.id.uuidString {
                    throw AgentActionsError.invalid("id and occurrence_id refer to different events; use just occurrence_id.")
                }
            } else if let rawID = args["id"] as? String, let id = UUID(uuidString: rawID) {
                guard let found = try await writer.ownedEvent(id: id) else {
                    throw AgentActionsError.invalid("No editable Attic-owned event has that id. Use calendar_search to find its occurrence_id.")
                }
                owned = found
            } else {
                throw AgentActionsError.invalid("Supply id or occurrence_id. calendar_search returns occurrence_id.")
            }
            args["id"] = owned.id.uuidString
            args["occurrence_id"] = owned.occurrenceID
            args["_expected_draft"] = try JSONEncoder().encode(owned.draft).base64EncodedString()
            args["_resolved_title"] = owned.draft.title
            if name == "calendar_update" {
                args["title"] = args["title"] ?? owned.draft.title
                args["calendar_id"] = args["calendar_id"] ?? owned.draft.calendarID
                args["time_zone"] = args["time_zone"] ?? owned.draft.timeZoneID
                args["all_day"] = args["all_day"] ?? owned.draft.isAllDay
                if let newStart = args["start"] {
                    if args["end"] == nil {
                        let date = try Self.isoDate(newStart, "start")
                        args["end"] = ISO8601DateFormatter().string(from: date.addingTimeInterval(
                            owned.draft.end.timeIntervalSince(owned.draft.start)))
                    }
                } else { args["start"] = ISO8601DateFormatter().string(from: owned.draft.start) }
                args["end"] = args["end"] ?? ISO8601DateFormatter().string(from: owned.draft.end)
                if args["notes"] == nil { args["notes"] = owned.draft.notes }
            }
        }
        if name == "calendar_create" || name == "calendar_update" {
            let calendars = try await writer.writableCalendars()
            let raw = args["calendar_id"] as? String
            if raw == nil, calendars.count == 1 { args["calendar_id"] = calendars[0].id }
            else if let raw {
                if !calendars.contains(where: { $0.id == raw }) {
                    let matches = calendars.filter { $0.title.localizedStandardCompare(raw) == .orderedSame }
                    if matches.count == 1 { args["calendar_id"] = matches[0].id }
                    else { throw AgentActionsError.invalid("Unknown or ambiguous calendar_id '\(raw)'. Call calendar_list_calendars; writable calendars: \(calendars.map { "\($0.title) (\($0.id))" }.joined(separator: "; ")).") }
                }
            } else {
                throw AgentActionsError.invalid("Specify calendar_id. Call calendar_list_calendars; writable calendars: \(calendars.map { "\($0.title) (\($0.id))" }.joined(separator: "; ")).")
            }
            guard let title = args["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentActionsError.invalid("Event title must be nonempty.")
            }
            let start = try Self.isoDate(args["start"], "start")
            if let end = args["end"] {
                guard try Self.isoDate(end, "end") > start else { throw AgentActionsError.invalid("Event end must be after start.") }
            }
        }
        return args
    }

    private static func ownedCalendarRow(_ event: CalendarOwnedEvent) -> [String: Any] {
        ["id": event.id.uuidString, "occurrence_id": event.occurrenceID,
         "title": event.draft.title, "start": ISO8601DateFormatter().string(from: event.draft.start),
         "end": ISO8601DateFormatter().string(from: event.draft.end),
         "calendar_id": event.draft.calendarID, "all_day": event.draft.isAllDay,
         "time_zone": event.draft.timeZoneID, "notes": event.draft.notes ?? ""]
    }

    func calendarAction(_ name: String, _ args: [String: Any], requestID: UUID) async throws -> (String, AgentStep, CalendarEventDraft?) {
        func result(_ text: String, _ kind: AgentStepKind, _ targets: [AgentTarget],
                    savedDraft: CalendarEventDraft? = nil) -> (String, AgentStep, CalendarEventDraft?) {
            (text, AgentStep(id: UUID(), title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                             kind: kind, targets: targets, state: .done), savedDraft)
        }
        switch name {
        case "calendar_search":
            guard let source = calendarSource, let query = args["query"] as? String,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentActionsError.invalid("Calendar search requires a nonempty query and an event source.")
            }
            let defaultStart = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-7 * 86_400)
            let start = try args["start"].map { try Self.isoDate($0, "start") } ??
                (args["end"] != nil ? Self.isoDate(args["end"], "end").addingTimeInterval(-30 * 86_400) : defaultStart)
            let end = try args["end"].map { try Self.isoDate($0, "end") } ?? start.addingTimeInterval(37 * 86_400)
            guard end > start, end.timeIntervalSince(start) <= 366 * 86_400 else {
                throw AgentActionsError.invalid("Calendar search interval must be positive and at most one year.")
            }
            let events = source.events(in: DateInterval(start: start, end: end)).filter {
                Self.matchScore(query: query, in: $0.title + " " + ($0.location ?? "")) != nil
            }
            return try result(Self.json(["events": events.map(Self.calendarRow), "count": events.count]),
                              .read, events.map(Self.calendarTarget))
        case "calendar_read":
            guard let source = calendarSource, let id = args["occurrence_id"] as? String,
                  let separator = id.lastIndex(of: "@"),
                  let seconds = Double(id[id.index(after: separator)...].split(separator: "#").first ?? ""),
                  seconds.isFinite else {
                throw AgentActionsError.invalid("A valid Calendar occurrence_id is required.")
            }
            let start = Date(timeIntervalSinceReferenceDate: seconds)
            let interval = DateInterval(start: start.addingTimeInterval(-1), end: start.addingTimeInterval(86_400))
            guard let event = source.events(in: interval).first(where: { $0.id == id }) else {
                throw AgentActionsError.invalid("Calendar occurrence not found.")
            }
            return try result(Self.json(["event": Self.calendarRow(event)]), .read, [Self.calendarTarget(event)])
        case "calendar_list_calendars":
            guard let writer = calendarWriter else { throw AgentActionsError.invalid("Calendar writer unavailable.") }
            let calendars = try await writer.writableCalendars()
            return try result(Self.json(["calendars": calendars.map { row in
                ["calendar_id": row.id, "title": row.title, "source": row.sourceTitle]
            }, "count": calendars.count]), .read, [])
        case "calendar_create", "calendar_update":
            guard let writer = calendarWriter, let title = args["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let calendarID = args["calendar_id"] as? String, !calendarID.isEmpty else {
                throw AgentActionsError.invalid("title and calendar_id are required. Use calendar_list_calendars to choose a calendar.")
            }
            let start = try Self.isoDate(args["start"], "start")
            let zone = (args["time_zone"] as? String) ?? TimeZone.current.identifier
            guard let timeZone = TimeZone(identifier: zone) else { throw AgentActionsError.invalid("Unknown time_zone '\(zone)'.") }
            let allDay = (args["all_day"] as? Bool) ?? false
            let end: Date
            if let rawEnd = args["end"] { end = try Self.isoDate(rawEnd, "end") }
            else if allDay {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            } else { end = start.addingTimeInterval(3600) }
            guard end > start else { throw AgentActionsError.invalid("end must be after start.") }
            let draft = CalendarEventDraft(title: title, start: start, end: end,
                                           isAllDay: allDay,
                                           calendarID: calendarID, timeZoneID: zone, notes: args["notes"] as? String)
            let saved: CalendarOwnedEvent
            if name == "calendar_create" {
                try guardMode(name, requestID: requestID)
                saved = try await writer.create(draft)
            }
            else {
                let expected = try await verifyCalendarBaseline(args, using: writer)
                try guardMode(name, requestID: requestID)
                saved = try await writer.edit(Self.uuid(args["id"], "id"), draft: draft, expecting: expected)
            }
            let target = AgentTarget(page: .calendar, itemID: saved.id, title: saved.draft.title,
                                     externalID: saved.occurrenceID)
            return try result(Self.json(Self.ownedCalendarRow(saved)), name == "calendar_create" ? .create : .update,
                              [target], savedDraft: saved.draft)
        case "calendar_delete":
            guard let writer = calendarWriter else { throw AgentActionsError.invalid("Calendar writer unavailable.") }
            let id = try Self.uuid(args["id"], "id")
            let expected = try await verifyCalendarBaseline(args, using: writer)
            try guardMode(name, requestID: requestID)
            try await writer.delete(id, expecting: expected)
            return try result(Self.json(["deleted": id.uuidString, "status": "deleted",
                                         "title": args["_resolved_title"] ?? "",
                                         "occurrence_id": args["occurrence_id"] ?? ""]), .delete,
                              [AgentTarget(page: .calendar, itemID: id, title: args["_resolved_title"] as? String,
                                           externalID: args["occurrence_id"] as? String)])
        default:
            throw AgentActionsError.invalid("Unknown Calendar action.")
        }
    }

    private func verifyCalendarBaseline(_ args: [String: Any], using writer: any CalendarEventWriter) async throws -> CalendarEventDraft {
        guard let encoded = args["_expected_draft"] as? String,
              let data = Data(base64Encoded: encoded),
              let expected = try? JSONDecoder().decode(CalendarEventDraft.self, from: data),
              let occurrence = args["occurrence_id"] as? String else {
            throw AgentActionsError.invalid("An approved Calendar baseline is required.")
        }
        guard let current = try await writer.ownedEvent(matching: occurrence), current.draft == expected else {
            throw AgentActionsError.invalid("This event changed while approval was pending. Call calendar_search to get its current occurrence_id, then retry the change.")
        }
        return expected
    }

    func drawAction(_ name: String, _ args: [String: Any], beforeMutation: () throws -> Void) throws -> (String, AgentStep, DrawSnapshot?) {
        guard let draw else { throw AgentActionsError.invalid("Draw store unavailable.") }
        if name == "draw_list_canvases" {
            let canvases = try draw.library(deleted: false)
            let text = try Self.json(["canvases": canvases.map { ["id": $0.id.uuidString, "name": $0.name] },
                                      "count": canvases.count])
            return (text, AgentStep(id: UUID(), title: "List Draw canvases", kind: .read,
                                    targets: canvases.map { AgentTarget(page: .draw, itemID: $0.id, title: $0.name) },
                                    state: .done), nil)
        }
        if name == "draw_create_canvas" {
            try beforeMutation()
            let canvas = draw.create(name: args["name"] as? String)
            let save = draw.performAgent(.saveCanvas, on: canvas.id)
            guard save.isSaved else { throw AgentActionsError.invalid("Draw canvas did not save: \(save)") }
            let saved = try draw.open(canvas.id)
            return (try Self.json(["canvas_id": canvas.id.uuidString, "canvas_name": saved.canvas.name]),
                    AgentStep(id: UUID(), title: "Create Draw canvas", kind: .create,
                              targets: [AgentTarget(page: .draw, itemID: canvas.id, title: saved.canvas.name)], state: .done), saved)
        }
        let canvasID = try Self.uuid(args["canvas_id"], "canvas_id")
        let snapshot = try draw.open(canvasID)
        if name == "draw_duplicate_canvas" {
            try beforeMutation()
            guard let copy = try draw.duplicate(canvasID, name: args["name"] as? String) else {
                throw AgentActionsError.invalid("Could not duplicate this Draw canvas.")
            }
            if snapshot.objects.isEmpty {
                let save = draw.performAgent(.saveCanvas, on: copy.id)
                guard save.isSaved else { throw AgentActionsError.invalid("Draw duplicate did not save: \(save)") }
            }
            guard try draw.library().contains(where: { $0.id == copy.id }) else {
                throw AgentActionsError.invalid("The new Draw canvas has not finished saving.")
            }
            let saved = try draw.open(copy.id)
            return (try Self.json(["canvas_id": copy.id.uuidString, "canvas_name": saved.canvas.name,
                                   "object_count": saved.objects.count]),
                    AgentStep(id: UUID(), title: "Duplicate Draw canvas", kind: .create,
                              targets: [AgentTarget(page: .draw, itemID: copy.id, title: saved.canvas.name)], state: .done), saved)
        }
        if name == "draw_read_canvas" {
            let objects: [[String: Any]] = snapshot.objects.prefix(100).map { object in
                var row: [String: Any] = [
                    "id": object.id.uuidString, "x": object.frame.x, "y": object.frame.y,
                    "width": object.frame.width, "height": object.frame.height,
                    "z_index": object.zIndex, "colour": object.style.colour.rawValue,
                    "size": object.style.size.rawValue, "corners": object.style.corners.rawValue,
                    "object_token": Self.drawToken(object)
                ]
                switch object.content {
                case let .text(text): row["kind"] = "text"; row["text"] = text
                case let .shape(shape): row["kind"] = "shape"; row["shape"] = shape.rawValue
                case let .stroke(points): row["kind"] = "stroke"; row["point_count"] = points.count
                case let .image(image):
                    row["kind"] = "image"
                    row["pixel_width"] = image.pixelWidth
                    row["pixel_height"] = image.pixelHeight
                }
                return row
            }
            let step = AgentStep(id: UUID(), title: "Read Draw canvas", kind: .read,
                                 targets: [AgentTarget(page: .draw, itemID: canvasID,
                                                       title: snapshot.canvas.name)], state: .done)
            return (try Self.json(["canvas_id": canvasID.uuidString, "canvas_name": snapshot.canvas.name,
                                   "objects": objects, "count": snapshot.objects.count,
                                   "truncated": snapshot.objects.count > objects.count]), step, nil)
        }
        if name == "draw_edit_text" {
            let objectID = try Self.uuid(args["object_id"], "object_id")
            guard var existing = snapshot.objects.first(where: { $0.id == objectID }),
                  case let .text(currentText) = existing.content else {
                throw AgentActionsError.invalid("That text box is no longer on this canvas. Read the canvas again.")
            }
            guard let expected = args["expected_text"] as? String, expected == currentText else {
                throw AgentActionsError.invalid("The text changed since it was read. Read the canvas again.")
            }
            guard let newText = args["text"] as? String, !newText.isEmpty else {
                throw AgentActionsError.invalid("Draw text must be nonempty.")
            }
            guard newText != currentText else { throw AgentActionsError.invalid("That text is already up to date.") }
            existing.content = .text(newText)
            try beforeMutation()
            let save = draw.performAgent(.put([existing]), on: canvasID)
            guard save.isSaved else { throw AgentActionsError.invalid("Draw text did not save: \(save)") }
            let after = try draw.open(canvasID)
            let step = AgentStep(id: UUID(), title: "Edit Draw text", kind: .update,
                                 targets: [AgentTarget(page: .draw, itemID: objectID,
                                                       title: snapshot.canvas.name, containerID: canvasID)], state: .done)
            return (try Self.json(["object_id": objectID.uuidString, "canvas_id": canvasID.uuidString,
                                   "text": newText]), step, after)
        }
        if name == "draw_move_object" {
            let objectID = try Self.uuid(args["object_id"], "object_id")
            guard let existing = snapshot.objects.first(where: { $0.id == objectID }) else {
                throw AgentActionsError.invalid("That object is no longer on this canvas. Read the canvas again.")
            }
            let x = try Self.number(args["x"], "x"), y = try Self.number(args["y"], "y")
            let expectedX = try Self.number(args["expected_x"], "expected_x")
            let expectedY = try Self.number(args["expected_y"], "expected_y")
            guard existing.frame.x == expectedX, existing.frame.y == expectedY else {
                throw AgentActionsError.invalid("The object moved since it was read. Read the canvas again.")
            }
            guard x != expectedX || y != expectedY else {
                throw AgentActionsError.invalid("The object is already at that position.")
            }
            let moved = existing.translated(by: DrawPoint(x: x - expectedX, y: y - expectedY), id: objectID)
            try beforeMutation()
            let save = draw.performAgent(.put([moved]), on: canvasID)
            guard save.isSaved else { throw AgentActionsError.invalid("Draw move did not save: \(save)") }
            let after = try draw.open(canvasID)
            let step = AgentStep(id: UUID(), title: "Move Draw object", kind: .move(toDay: nil),
                                 targets: [AgentTarget(page: .draw, itemID: objectID,
                                                       title: snapshot.canvas.name, containerID: canvasID)], state: .done)
            return (try Self.json(["object_id": objectID.uuidString, "canvas_id": canvasID.uuidString,
                                   "x": x, "y": y]), step, after)
        }
        if ["draw_delete_object", "draw_restyle_object", "draw_resize_object"].contains(name) {
            let objectID = try Self.uuid(args["object_id"], "object_id")
            guard let existing = snapshot.objects.first(where: { $0.id == objectID }) else {
                throw AgentActionsError.invalid("That object is no longer on this canvas. Read the canvas again.")
            }
            guard let token = args["object_token"] as? String, token == Self.drawToken(existing) else {
                throw AgentActionsError.invalid("The object changed since it was read. Read the canvas again.")
            }
            let command: DrawCommand
            let kind: AgentStepKind
            switch name {
            case "draw_delete_object":
                command = .remove([objectID]); kind = .delete
            case "draw_restyle_object":
                guard args["colour"] != nil || args["size"] != nil || args["corners"] != nil else {
                    throw AgentActionsError.invalid("Specify a colour, size or corners to change.")
                }
                var styled = existing
                styled.style = DrawStyle(
                    colour: try Self.enumValue(DrawColour.self, args["colour"], name: "colour", default: existing.style.colour),
                    size: try Self.enumValue(DrawSize.self, args["size"], name: "size", default: existing.style.size),
                    corners: try Self.enumValue(DrawCorners.self, args["corners"], name: "corners", default: existing.style.corners))
                guard styled != existing else { throw AgentActionsError.invalid("The object already has that style.") }
                command = .put([styled]); kind = .update
            default:
                let width = try Self.number(args["width"], "width")
                let height = try Self.number(args["height"], "height")
                guard width > 0, height > 0 else { throw AgentActionsError.invalid("Draw dimensions must be positive.") }
                let resized = DrawPageModel.resized([existing], handle: .bottomRight,
                    delta: CGPoint(x: width - existing.frame.width, y: height - existing.frame.height), shift: false)
                guard let updated = resized.first, updated != existing else {
                    throw AgentActionsError.invalid("The object already has that size.")
                }
                command = .put([updated]); kind = .update
            }
            try beforeMutation()
            let save = draw.performAgent(command, on: canvasID)
            guard save.isSaved else { throw AgentActionsError.invalid("Draw change did not save: \(save)") }
            let after = try draw.open(canvasID)
            let step = AgentStep(id: UUID(), title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                                 kind: kind, targets: [AgentTarget(page: .draw, itemID: objectID,
                                                                   title: snapshot.canvas.name, containerID: canvasID)],
                                 state: .done)
            return (try Self.json(["canvas_id": canvasID.uuidString, "canvas_name": snapshot.canvas.name,
                                   "object_id": objectID.uuidString, "deleted": name == "draw_delete_object"]),
                    step, after)
        }
        if name == "draw_rename_canvas" || name == "draw_delete_canvas" {
            let command: DrawCommand
            let kind: AgentStepKind
            if name == "draw_rename_canvas" {
                guard let expected = args["expected_name"] as? String, expected == snapshot.canvas.name else {
                    throw AgentActionsError.invalid("The canvas name changed. List canvases again.")
                }
                guard let newName = args["name"] as? String,
                      !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AgentActionsError.invalid("Provide a nonempty canvas name.")
                }
                guard newName.trimmingCharacters(in: .whitespacesAndNewlines) != snapshot.canvas.name else {
                    throw AgentActionsError.invalid("The canvas already has that name.")
                }
                command = .rename(newName)
                kind = .update
            } else {
                guard snapshot.canvas.deletedAt == nil else {
                    throw AgentActionsError.invalid("This canvas is already deleted.")
                }
                command = .deleteCanvas
                kind = .delete
            }
            try beforeMutation()
            let save = draw.performAgent(command, on: canvasID)
            guard save.isSaved else { throw AgentActionsError.invalid("Draw change did not save: \(save)") }
            let after = try draw.open(canvasID)
            let step = AgentStep(id: UUID(), title: name == "draw_rename_canvas" ? "Rename Draw canvas" : "Delete Draw canvas",
                                 kind: kind, targets: [AgentTarget(page: .draw, itemID: canvasID,
                                                                   title: after.canvas.name)], state: .done)
            return (try Self.json(["canvas_id": canvasID.uuidString, "canvas_name": after.canvas.name,
                                   "deleted": after.canvas.deletedAt != nil]), step, after)
        }
        let colour = try Self.enumValue(DrawColour.self, args["colour"], name: "colour", default: .ink)
        let size = try Self.enumValue(DrawSize.self, args["size"], name: "size", default: .medium)
        let corners = try Self.enumValue(DrawCorners.self, args["corners"], name: "corners", default: .square)
        let style = DrawStyle(colour: colour, size: size, corners: corners)
        let frame: DrawFrame
        let content: DrawContent
        switch name {
        case "draw_add_text", "draw_add_shape":
            let x = try Self.number(args["x"], "x")
            let y = try Self.number(args["y"], "y")
            let width = try Self.number(args["width"], "width", fallback: 160)
            let height = try Self.number(args["height"], "height", fallback: 48)
            guard width > 0, height > 0 else { throw AgentActionsError.invalid("Draw dimensions must be positive.") }
            frame = DrawFrame(x: x, y: y, width: width, height: height)
            if name == "draw_add_text" {
                guard let text = args["text"] as? String, !text.isEmpty else {
                    throw AgentActionsError.invalid("Text must be nonempty.")
                }
                content = .text(text)
            } else {
                guard let raw = args["shape"] as? String, let shape = DrawShape(rawValue: raw) else {
                    throw AgentActionsError.invalid("Unknown Draw shape.")
                }
                content = .shape(shape)
            }
        case "draw_add_strokes":
            guard let raw = args["points"] as? [[String: Any]], (2...1000).contains(raw.count) else {
                throw AgentActionsError.invalid("Provide 2 to 1000 stroke points.")
            }
            let points = try raw.map { DrawPoint(x: try Self.number($0["x"], "x"),
                                                  y: try Self.number($0["y"], "y")) }
            let xs = points.map(\.x), ys = points.map(\.y)
            frame = DrawFrame(x: xs.min()!, y: ys.min()!, width: max(1, xs.max()! - xs.min()!),
                              height: max(1, ys.max()! - ys.min()!))
            content = .stroke(points)
        default:
            throw AgentActionsError.invalid("Unknown Draw action.")
        }
        let object = DrawObject(frame: frame, zIndex: (snapshot.objects.map(\.zIndex).max() ?? 0) + 1,
                                style: style, content: content)
        try beforeMutation()
        let save = draw.performAgent(.put([object]), on: canvasID)
        guard save.isSaved else {
            throw AgentActionsError.invalid("Draw edit did not save: \(String(describing: save))")
        }
        let after = try draw.open(canvasID)
        let step = AgentStep(id: UUID(), title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                             kind: .create,
                             targets: [AgentTarget(page: .draw, itemID: object.id, title: snapshot.canvas.name,
                                                   containerID: canvasID)], state: .done)
        var row: [String: Any] = ["id": object.id.uuidString, "canvas_id": canvasID.uuidString,
                                  "canvas_name": snapshot.canvas.name, "x": frame.x, "y": frame.y,
                                  "width": frame.width, "height": frame.height, "z_index": object.zIndex,
                                  "colour": colour.rawValue, "size": size.rawValue, "corners": corners.rawValue]
        switch content {
        case let .text(text): row["text"] = text; row["kind"] = "text"
        case let .shape(shape): row["shape"] = shape.rawValue; row["kind"] = "shape"
        case let .stroke(points):
            row["points"] = points.map { ["x": $0.x, "y": $0.y] }
            row["kind"] = "stroke"
        case .image: break
        }
        return (try Self.json(["object_id": object.id.uuidString, "canvas_id": canvasID.uuidString,
                               "object": row]), step, after)
    }

    private static func enumValue<T: RawRepresentable>(_ type: T.Type, _ input: Any?, name: String,
                                                      default defaultValue: T) throws -> T where T.RawValue == String {
        guard let input else { return defaultValue }
        guard let raw = input as? String, let value = T(rawValue: raw) else {
            throw AgentActionsError.invalid("Invalid \(name).")
        }
        return value
    }

    /// Include the object's full content so approval cannot silently discard
    /// an owner edit to a stroke or image between Read and Apply.
    private static func drawToken(_ object: DrawObject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(object) else { return "" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
