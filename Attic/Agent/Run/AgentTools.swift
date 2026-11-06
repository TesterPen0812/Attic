import Foundation

/// JSON values travel across actor boundaries without untyped Any dictionaries.
indirect enum AgentJSON: Codable, Sendable, Equatable {
    case object([String: AgentJSON])
    case array([AgentJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let object = try? value.decode([String: AgentJSON].self) { self = .object(object) }
        else { self = .array(try value.decode([AgentJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: AgentJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var array: [AgentJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The existing AgentTaskTools boundary accepts Foundation values.
    var foundation: Any {
        switch self {
        case let .object(value): return value.mapValues(\.foundation)
        case let .array(value): return value.map(\.foundation)
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case .null: return NSNull()
        }
    }

    static func convert(_ value: Any) throws -> AgentJSON {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(AgentJSON.self, from: data)
    }
}

struct AgentToolDefinition: Sendable {
    let name: String
    let description: String
    let schema: AgentJSON

    var apiValue: AgentJSON {
        .object(["name": .string(name), "description": .string(description),
                 "input_schema": schema, "eager_input_streaming": .bool(true)])
    }
}

struct AgentToolResponse: Sendable {
    let content: String
    var step: AgentStep? = nil
    var changes: AgentChangeSet? = nil
    /// The provider must return this *before* applying a protected change.
    /// Calling the same tool with approved=true is permitted only after resolve.
    var approval: AgentApproval? = nil
}

/// A narrow seam until AgentActions owns tool execution and approval policy.
@MainActor
protocol AgentToolProviding: AnyObject {
    func listTools() async throws -> [AgentToolDefinition]
    func call(name: String, arguments: [String: AgentJSON], approved: Bool) async throws -> AgentToolResponse
    func setWatching(_ watching: Bool)
}

extension AgentToolProviding {
    func setWatching(_ watching: Bool) {}
}

/// Adapter for the existing task tool layer. The future AgentActions adapter
/// can implement AgentToolProviding without changing the run engine.
@MainActor
final class AgentTaskToolProvider: AgentToolProviding {
    private let tools: AgentTaskTools
    init(tools: AgentTaskTools) { self.tools = tools }

    func listTools() async throws -> [AgentToolDefinition] {
        try tools.definitions.map { definition in
            guard let name = definition["name"] as? String,
                  let description = definition["description"] as? String,
                  let schema = definition["inputSchema"] else {
                throw AgentRunnerError.protocolViolation
            }
            return try AgentToolDefinition(name: name, description: description,
                                           schema: AgentJSON.convert(schema))
        }
    }

    func call(name: String, arguments: [String: AgentJSON], approved: Bool) async throws -> AgentToolResponse {
        guard let definition = tools.definitions.first(where: { $0["name"] as? String == name }) else {
            throw AgentToolError.unknownTool(name)
        }
        let annotations = definition["annotations"] as? [String: Any] ?? [:]
        if !approved && annotations["readOnlyHint"] as? Bool != true {
            return AgentToolResponse(content: "", approval: AgentApproval(
                id: UUID(), title: "Allow \(name.replacingOccurrences(of: "_", with: " "))?", targets: []))
        }
        let raw = arguments.mapValues(\.foundation)
        let result: String
        if AgentTaskTools.asyncToolNames.contains(name) {
            result = try await tools.callAsync(name: name, arguments: raw)
        } else {
            result = try tools.call(name: name, arguments: raw)
        }
        return AgentToolResponse(content: result)
    }
}

/// Validate eager streamed JSON against the same schema advertised to Claude.
/// Unsupported schema constraints fail closed instead of executing unknown input.
enum AgentToolSchema {
    static func accepts(_ value: AgentJSON, schema: AgentJSON) -> Bool {
        guard let rules = schema.object else { return false }
        if let choices = rules["enum"]?.array, !choices.contains(value) { return false }
        if let fixed = rules["const"], fixed != value { return false }
        if let alternatives = rules["anyOf"]?.array, !alternatives.contains(where: { accepts(value, schema: $0) }) { return false }
        if let alternatives = rules["oneOf"]?.array, alternatives.filter({ accepts(value, schema: $0) }).count != 1 { return false }
        if let all = rules["allOf"]?.array, !all.allSatisfy({ accepts(value, schema: $0) }) { return false }
        if rules["$ref"] != nil || rules["not"] != nil { return false }
        let types = rules["type"]?.array?.compactMap(\.string) ?? rules["type"]?.string.map { [$0] } ?? []
        if !types.isEmpty && !types.contains(where: { matches(value, type: $0) }) { return false }

        switch value {
        case let .object(input):
            let properties = rules["properties"]?.object ?? [:]
            if let required = rules["required"]?.array?.compactMap(\.string),
               !required.allSatisfy({ input[$0] != nil }) { return false }
            for (name, nested) in input {
                if let property = properties[name] {
                    if !accepts(nested, schema: property) { return false }
                } else if rules["additionalProperties"] == .bool(false) { return false }
                else if let extra = rules["additionalProperties"], case .object = extra,
                        !accepts(nested, schema: extra) { return false }
            }
            if let min = numeric(rules["minProperties"]), Double(input.count) < min { return false }
            if let max = numeric(rules["maxProperties"]), Double(input.count) > max { return false }
        case let .array(input):
            if let itemSchema = rules["items"], !input.allSatisfy({ accepts($0, schema: itemSchema) }) { return false }
            if let min = numeric(rules["minItems"]), Double(input.count) < min { return false }
            if let max = numeric(rules["maxItems"]), Double(input.count) > max { return false }
            if rules["uniqueItems"] == .bool(true), Set(input.map { String(describing: $0) }).count != input.count { return false }
        case let .string(input):
            if let min = numeric(rules["minLength"]), Double(input.unicodeScalars.count) < min { return false }
            if let max = numeric(rules["maxLength"]), Double(input.unicodeScalars.count) > max { return false }
            if let pattern = rules["pattern"]?.string {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil else { return false }
            }
        case let .number(input):
            if let min = numeric(rules["minimum"]), input < min { return false }
            if let max = numeric(rules["maximum"]), input > max { return false }
            if let min = numeric(rules["exclusiveMinimum"]), input <= min { return false }
            if let max = numeric(rules["exclusiveMaximum"]), input >= max { return false }
        default: break
        }
        return true
    }

    private static func numeric(_ value: AgentJSON?) -> Double? {
        if case let .number(n)? = value { return n }
        return nil
    }

    private static func matches(_ value: AgentJSON, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string),
             ("number", .number), ("boolean", .bool), ("null", .null): true
        case ("integer", let .number(n)): n.isFinite && n.rounded() == n
        default: false
        }
    }
}
