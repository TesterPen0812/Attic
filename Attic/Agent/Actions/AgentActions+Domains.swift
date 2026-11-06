import Foundation

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
        let canvas: [String: Any] = ["canvas_id": string]
        let eventFields: [String: Any] = [
            "title": string, "start": string, "end": string, "calendar_id": string,
            "time_zone": string, "all_day": ["type": "boolean"], "notes": string
        ]
        let span: [String: Any] = ["start": string, "end": string]
        return [
            definition("open_page", "Open an Attic page only while its owner is watching.",
                       ["page": ["type": "string", "enum": AgentPage.allCases.map(\.rawValue)]], required: ["page"]),
            definition("calendar_search", "Search Calendar occurrences in the supplied ISO-8601 date interval.",
                       span.merging(["query": string]) { _, new in new }, required: ["query", "start", "end"]),
            definition("calendar_read", "Read one Calendar occurrence by its occurrence_id from search results.",
                       ["occurrence_id": string], required: ["occurrence_id"]),
            definition("calendar_create", "Create an event in a writable Calendar. End is exclusive; times include a UTC offset.",
                       eventFields, required: ["title", "start", "end", "calendar_id"]),
            definition("calendar_update", "Replace all values of an Attic-owned Calendar event by its UUID.",
                       eventFields.merging(["id": string]) { _, new in new },
                       required: ["id", "title", "start", "end", "calendar_id"]),
            definition("calendar_delete", "Delete an Attic-owned Calendar event by UUID.",
                       ["id": string], required: ["id"]),
            definition("draw_list_canvases", "List live Draw canvases and their IDs.", [:]),
            definition("draw_add_text", "Add a text box to an existing Draw canvas; geometry is in points.",
                       canvas.merging(frame.merging(style) { _, new in new }.merging(["text": string]) { _, new in new }) { _, new in new },
                       required: ["canvas_id", "text", "x", "y"]),
            definition("draw_add_shape", "Add a rectangle, ellipse, line or arrow to Draw.",
                       canvas.merging(frame.merging(style) { _, new in new }.merging([
                        "shape": ["type": "string", "enum": DrawShape.allCases.map(\.rawValue)]
                       ]) { _, new in new }) { _, new in new },
                       required: ["canvas_id", "shape", "x", "y", "width", "height"]),
            definition("draw_add_strokes", "Add a freehand stroke with absolute point coordinates.",
                       canvas.merging(style.merging(["points": [
                        "type": "array", "minItems": 2, "maxItems": 1000,
                        "items": schema(position, required: ["x", "y"])
                       ]]) { _, new in new }) { _, new in new },
                       required: ["canvas_id", "points"])
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

    func calendarAction(_ name: String, _ args: [String: Any]) async throws -> (String, AgentStep) {
        func result(_ text: String, _ kind: AgentStepKind, _ targets: [AgentTarget]) -> (String, AgentStep) {
            (text, AgentStep(id: UUID(), title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                             kind: kind, targets: targets, state: .done))
        }
        switch name {
        case "calendar_search":
            guard let source = calendarSource, let query = args["query"] as? String,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentActionsError.invalid("Calendar search requires a nonempty query and an event source.")
            }
            let start = try Self.isoDate(args["start"], "start")
            let end = try Self.isoDate(args["end"], "end")
            guard end > start, end.timeIntervalSince(start) <= 366 * 86_400 else {
                throw AgentActionsError.invalid("Calendar search interval must be positive and at most one year.")
            }
            let events = source.search(query, in: DateInterval(start: start, end: end))
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
        case "calendar_create", "calendar_update":
            guard let writer = calendarWriter, let title = args["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let calendarID = args["calendar_id"] as? String, !calendarID.isEmpty else {
                throw AgentActionsError.invalid("title and calendar_id are required.")
            }
            let start = try Self.isoDate(args["start"], "start")
            let end = try Self.isoDate(args["end"], "end")
            guard end > start else { throw AgentActionsError.invalid("end must be after start.") }
            let zone = (args["time_zone"] as? String) ?? TimeZone.current.identifier
            guard TimeZone(identifier: zone) != nil else { throw AgentActionsError.invalid("Unknown time_zone.") }
            let draft = CalendarEventDraft(title: title, start: start, end: end,
                                           isAllDay: (args["all_day"] as? Bool) ?? false,
                                           calendarID: calendarID, timeZoneID: zone, notes: args["notes"] as? String)
            let saved: CalendarOwnedEvent
            if name == "calendar_create" { saved = try await writer.create(draft) }
            else { saved = try await writer.edit(Self.uuid(args["id"], "id"), draft: draft) }
            let target = AgentTarget(page: .calendar, itemID: saved.id, title: saved.draft.title,
                                     externalID: saved.occurrenceID)
            return try result(Self.json(["id": saved.id.uuidString, "occurrence_id": saved.occurrenceID,
                                         "title": saved.draft.title]), name == "calendar_create" ? .create : .update, [target])
        case "calendar_delete":
            guard let writer = calendarWriter else { throw AgentActionsError.invalid("Calendar writer unavailable.") }
            let id = try Self.uuid(args["id"], "id")
            try await writer.delete(id)
            return try result(Self.json(["deleted": id.uuidString]), .delete,
                              [AgentTarget(page: .calendar, itemID: id)])
        default:
            throw AgentActionsError.invalid("Unknown Calendar action.")
        }
    }

    func drawAction(_ name: String, _ args: [String: Any]) throws -> (String, AgentStep, DrawSnapshot?) {
        guard let draw else { throw AgentActionsError.invalid("Draw store unavailable.") }
        if name == "draw_list_canvases" {
            let canvases = try draw.library(deleted: false)
            let text = try Self.json(["canvases": canvases.map { ["id": $0.id.uuidString, "name": $0.name] },
                                      "count": canvases.count])
            return (text, AgentStep(id: UUID(), title: "List Draw canvases", kind: .read,
                                    targets: canvases.map { AgentTarget(page: .draw, itemID: $0.id, title: $0.name) },
                                    state: .done), nil)
        }
        let canvasID = try Self.uuid(args["canvas_id"], "canvas_id")
        let snapshot = try draw.open(canvasID)
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
        let save = draw.perform(.put([object]), on: canvasID)
        guard save.isSaved else {
            throw AgentActionsError.invalid("Draw edit did not save: \(String(describing: save))")
        }
        let after = try draw.open(canvasID)
        let step = AgentStep(id: UUID(), title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                             kind: .create,
                             targets: [AgentTarget(page: .draw, itemID: object.id, title: snapshot.canvas.name,
                                                   containerID: canvasID)], state: .done)
        return (try Self.json(["object_id": object.id.uuidString, "canvas_id": canvasID.uuidString]), step, after)
    }

    private static func enumValue<T: RawRepresentable>(_ type: T.Type, _ input: Any?, name: String,
                                                      default defaultValue: T) throws -> T where T.RawValue == String {
        guard let input else { return defaultValue }
        guard let raw = input as? String, let value = T(rawValue: raw) else {
            throw AgentActionsError.invalid("Invalid \(name).")
        }
        return value
    }
}
