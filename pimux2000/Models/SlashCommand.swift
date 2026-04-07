import Foundation

struct SlashCommandArgumentCompletion: Identifiable, Equatable, Sendable {
	let value: String
	let label: String
	let description: String?

	var id: String { "\(value)|\(label)|\(description ?? "")" }
}

struct SlashCommandDraftContext: Equatable, Sendable {
	enum Phase: Equatable, Sendable {
		case commandName(prefix: String)
		case arguments(commandName: String, argumentText: String)
	}

	let rawText: String
	let phase: Phase
}

struct SlashCommand: Identifiable, Equatable, Sendable {
	let name: String
	let description: String
	let source: String // "builtin", "extension", "prompt", "skill"

	var id: String { name }
	var displayName: String { "/\(name)" }

	private enum BuiltinArgumentRule {
		case none(usage: String)
		case requiredText(usage: String)
		case optionalText
		case requiredExactValues(usage: String, completions: [SlashCommandArgumentCompletion])
	}

	private var builtinArgumentRule: BuiltinArgumentRule? {
		guard source == "builtin" else { return nil }

		switch name {
		case "copy":
			return .none(usage: "/copy")
		case "new":
			return .none(usage: "/new")
		case "fork":
			return .none(usage: "/fork")
		case "session":
			return .none(usage: "/session")
		case "reload":
			return .none(usage: "/reload")
		case "name":
			return .requiredText(usage: "/name <name>")
		case "compact":
			return .optionalText
		case "pimux":
			return .requiredExactValues(
				usage: "/pimux resummarize",
				completions: [
					SlashCommandArgumentCompletion(
						value: "resummarize",
						label: "resummarize",
						description: "Regenerate the session summary"
					),
				]
			)
		default:
			return nil
		}
	}

	static let builtinCommands: [SlashCommand] = [
		SlashCommand(name: "compact", description: "Manually compact the session context", source: "builtin"),
		SlashCommand(name: "pimux", description: "Pimux helpers like resummarize", source: "builtin"),
		SlashCommand(name: "name", description: "Set session display name", source: "builtin"),
		SlashCommand(name: "new", description: "Start a new session", source: "builtin"),
		SlashCommand(name: "fork", description: "Create a new fork from a previous message", source: "builtin"),
		SlashCommand(name: "copy", description: "Copy last agent message to clipboard", source: "builtin"),
		SlashCommand(name: "session", description: "Show session info and stats", source: "builtin"),
		SlashCommand(name: "reload", description: "Reload keybindings, extensions, skills, prompts, and themes", source: "builtin"),
	]

	static func merged(builtins: [SlashCommand] = builtinCommands, custom: [PimuxSessionCommand]) -> [SlashCommand] {
		let builtinNames = Set(builtins.map(\.name))
		let customCommands = custom
			.filter { !builtinNames.contains($0.name) }
			.map { SlashCommand(name: $0.name, description: $0.description ?? "", source: $0.source) }
		return builtins + customCommands
	}

	static func matching(query: String, from commands: [SlashCommand]) -> [SlashCommand] {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.hasPrefix("/") else { return [] }

		let filter = String(trimmed.dropFirst()).lowercased()
		if filter.isEmpty { return commands }

		return commands.filter { $0.name.lowercased().hasPrefix(filter) }
	}

	static func command(named name: String, from commands: [SlashCommand]) -> SlashCommand? {
		commands.first { $0.name == name }
	}

	static func draftContext(for text: String) -> SlashCommandDraftContext? {
		guard text.hasPrefix("/"), !text.contains("\n") else { return nil }

		let withoutSlash = String(text.dropFirst())
		guard !withoutSlash.isEmpty || text == "/" else { return nil }

		guard let spaceIndex = withoutSlash.firstIndex(of: " ") else {
			return SlashCommandDraftContext(rawText: text, phase: .commandName(prefix: withoutSlash))
		}

		let commandName = String(withoutSlash[..<spaceIndex])
		let argumentStart = withoutSlash.index(after: spaceIndex)
		let argumentText = String(withoutSlash[argumentStart...])
		return SlashCommandDraftContext(rawText: text, phase: .arguments(commandName: commandName, argumentText: argumentText))
	}

	func localArgumentCompletions(argumentPrefix: String) -> [SlashCommandArgumentCompletion] {
		guard let builtinArgumentRule else { return [] }

		switch builtinArgumentRule {
		case let .requiredExactValues(_, completions):
			let trimmed = argumentPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if trimmed.isEmpty { return completions }
			return completions.filter { completion in
				completion.value.lowercased().hasPrefix(trimmed)
			}
		case .none, .requiredText, .optionalText:
			return []
		}
	}

	func validationMessage(argumentText: String?) -> String? {
		guard let builtinArgumentRule else { return nil }

		let trimmedArgument = argumentText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

		switch builtinArgumentRule {
		case let .none(usage):
			return trimmedArgument.isEmpty ? nil : "Usage: \(usage)"
		case let .requiredText(usage):
			return trimmedArgument.isEmpty ? "Usage: \(usage)" : nil
		case .optionalText:
			return nil
		case let .requiredExactValues(usage, completions):
			guard !trimmedArgument.isEmpty else { return "Usage: \(usage)" }
			return completions.contains(where: { $0.value == trimmedArgument }) ? nil : "Usage: \(usage)"
		}
	}

	static func validationMessage(for text: String, commands: [SlashCommand]) -> String? {
		guard let context = draftContext(for: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
			return nil
		}

		switch context.phase {
		case let .commandName(prefix):
			guard !prefix.isEmpty else { return nil }
			guard let command = command(named: prefix, from: commands) else {
				return matching(query: "/\(prefix)", from: commands).isEmpty ? "Unknown slash command: /\(prefix)" : nil
			}
			return command.validationMessage(argumentText: nil)
		case let .arguments(commandName, argumentText):
			guard !commandName.isEmpty else { return nil }
			guard let command = command(named: commandName, from: commands) else {
				return "Unknown slash command: /\(commandName)"
			}
			return command.validationMessage(argumentText: argumentText)
		}
	}
}
