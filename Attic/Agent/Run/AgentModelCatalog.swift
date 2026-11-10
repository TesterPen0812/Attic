import Foundation

// Compiled into both Attic and AtticAgentHelper. The app offers only these
// choices, and the unsandboxed helper refuses anything else before it builds a
// command line, so no free text from the app reaches a CLI's arguments.

enum AgentBackend: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var title: String { self == .claude ? "Claude Code" : "Codex" }
    /// The chat's agent menu says just the name.
    var shortTitle: String { self == .claude ? "Claude" : "Codex" }
    var loginCommand: String { self == .claude ? "claude auth login" : "codex login" }
}

/// One model Attic offers an in-app agent, with the thinking levels its CLI
/// accepts for it (empty when the CLI takes no level for that model).
struct AgentModelOption: Equatable, Sendable {
    let id: String
    let title: String
    let efforts: [String]
}

/// The model and thinking level a run is started with.
struct AgentRunChoice: Equatable, Codable, Sendable {
    var model: String
    var effort: String?
}

enum AgentModelCatalog {
    static let defaultEffort = "medium"

    // Claude Code 2.1.316: `--model <alias>` takes "opus", "sonnet" and
    // "haiku" (its alias table), `--effort` takes low, medium, high, xhigh, max,
    // and its model table gives the current Opus, Sonnet and Haiku all five.
    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    // Codex 0.167.0: the model catalog it ships (`codex debug models --bundled`)
    // lists these slugs and the reasoning levels each one advertises.
    private static let codexFullEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    static func models(for backend: AgentBackend) -> [AgentModelOption] {
        switch backend {
        case .claude:
            return [
                AgentModelOption(id: "opus", title: "Opus", efforts: claudeEfforts),
                AgentModelOption(id: "sonnet", title: "Sonnet", efforts: claudeEfforts),
                AgentModelOption(id: "haiku", title: "Haiku", efforts: claudeEfforts)
            ]
        case .codex:
            return [
                AgentModelOption(id: "gpt-6.1-sol", title: "GPT-6.1 Sol", efforts: codexFullEfforts),
                AgentModelOption(id: "gpt-6.1-terra", title: "GPT-6.1 Terra", efforts: codexFullEfforts),
                AgentModelOption(id: "gpt-6-astra", title: "GPT-6 Astra", efforts: codexFullEfforts),
                AgentModelOption(id: "gpt-6-luna", title: "GPT-6 Luna",
                                 efforts: ["low", "medium", "high", "xhigh", "max"])
            ]
        }
    }

    static func defaultChoice(for backend: AgentBackend) -> AgentRunChoice {
        AgentRunChoice(model: backend == .claude ? "sonnet" : "gpt-6.1-sol", effort: defaultEffort)
    }

    static func model(_ id: String, for backend: AgentBackend) -> AgentModelOption? {
        models(for: backend).first { $0.id == id }
    }

    static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return effort
        }
    }

    /// A stored or edited choice made valid for `backend`: an unlisted model
    /// becomes the default, and a level the model does not take becomes
    /// medium (or none, for a model without levels).
    static func normalized(_ choice: AgentRunChoice?, for backend: AgentBackend) -> AgentRunChoice {
        let fallback = defaultChoice(for: backend)
        guard let choice, let option = model(choice.model, for: backend) else { return fallback }
        guard !option.efforts.isEmpty else { return AgentRunChoice(model: option.id, effort: nil) }
        if let effort = choice.effort, option.efforts.contains(effort) {
            return AgentRunChoice(model: option.id, effort: effort)
        }
        return AgentRunChoice(model: option.id,
                              effort: option.efforts.contains(defaultEffort) ? defaultEffort : option.efforts.first)
    }

    /// The CLI arguments for a listed choice, or nil when the backend, model
    /// or level is not one Attic lists. Never normalizes: the helper refuses.
    static func launchArguments(backend name: String, model: String, effort: String?) -> [String]? {
        guard let backend = AgentBackend(rawValue: name),
              let option = self.model(model, for: backend) else { return nil }
        if option.efforts.isEmpty {
            guard effort == nil else { return nil }
        } else {
            guard let effort, option.efforts.contains(effort) else { return nil }
        }
        switch backend {
        case .claude:
            return ["--model", option.id] + (effort.map { ["--effort", $0] } ?? [])
        case .codex:
            // `codex app-server` has no -m flag; it takes config overrides.
            return ["--config", "model=\"\(option.id)\""]
                + (effort.map { ["--config", "model_reasoning_effort=\"\($0)\""] } ?? [])
        }
    }
}
