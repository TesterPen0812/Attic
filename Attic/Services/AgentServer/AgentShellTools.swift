import Foundation

/// What an agent asks the panel to show.
enum AgentShowTarget: Equatable {
    case page(PanelPage)
    case item(AtticItemRef)
}

/// What happened when an agent asked to show something.
enum AgentShowOutcome: Equatable {
    case shown(String)
    /// The person is typing in Attic; nothing moved.
    case userIsTyping
    case notFound(String)
    /// The panel could not show it; the details say why (nothing that
    /// was refused changed).
    case failed(String)
}

/// Shows pages and items for an agent. `PanelAgentPresenter` implements it
/// over the real panel.
@MainActor
protocol AgentPanelPresenting: AnyObject {
    func presentForAgent(_ target: AgentShowTarget) -> AgentShowOutcome
}

/// The shell's MCP tools: `show` opens a page or an item for the person in
/// the panel (spec § Agent access). It never takes the keyboard, and it
/// refuses to move anything while the person is typing in Attic.
@MainActor
final class AgentShellTools {
    weak var presenter: AgentPanelPresenting?

    static let definitions: [[String: Any]] = [
        [
            "name": "show",
            "title": "Show in Attic",
            "description": "Open a page (tasks, notes, canvas) or an item (a task, note or canvas by id) for the user in the Attic panel. Use it only when the user asked to see something. It never takes the keyboard from the app the user is in, and it changes nothing while the user is typing in Attic (the result says so).",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "page": [
                        "type": "string",
                        "enum": PanelPage.allCases.map(\.rawValue),
                        "description": "The page to open."
                    ],
                    "item": [
                        "type": "object",
                        "properties": [
                            "kind": ["type": "string", "enum": AtticItemKind.allCases.map(\.rawValue)],
                            "id": ["type": "string", "description": "The item's UUID."]
                        ],
                        "required": ["kind", "id"],
                        "additionalProperties": false
                    ]
                ],
                "additionalProperties": false
            ]
        ]
    ]

    var definitions: [[String: Any]] { Self.definitions }

    func handles(_ name: String) -> Bool { name == "show" }

    func call(name: String, arguments: [String: Any]) throws -> String {
        guard name == "show" else { throw AgentToolError.unknownTool(name) }
        let target = try Self.target(from: arguments)
        guard let presenter else {
            throw AgentToolError.storeFailure("Attic's panel is not available.")
        }
        switch presenter.presentForAgent(target) {
        case let .shown(description):
            return "Shown: \(description)."
        case .userIsTyping:
            return "Not shown: the user is typing in Attic. Nothing was moved; ask again later or tell the user where to look."
        case let .notFound(description):
            throw AgentToolError.invalidArguments("No \(description) exists with that id.")
        case let .failed(reason):
            throw AgentToolError.notPerformed("Not shown: \(reason)")
        }
    }

    static func target(from arguments: [String: Any]) throws -> AgentShowTarget {
        let page = arguments["page"]
        let item = arguments["item"]
        switch (page, item) {
        case let (page as String, nil):
            guard let resolved = PanelPage(rawValue: page) else {
                throw AgentToolError.invalidArguments("page must be one of: \(PanelPage.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return .page(resolved)
        case let (nil, item as [String: Any]):
            guard let kind = (item["kind"] as? String).flatMap(AtticItemKind.init(rawValue:)),
                  let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                throw AgentToolError.invalidArguments("item needs a kind (task, note or canvas) and a UUID id.")
            }
            return .item(AtticItemRef(kind, id))
        default:
            throw AgentToolError.invalidArguments("Give exactly one of page or item.")
        }
    }
}
