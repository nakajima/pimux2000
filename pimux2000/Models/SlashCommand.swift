import Foundation

struct SlashCommand: Identifiable, Equatable {
	let name: String
	let description: String
	let source: String // "builtin", "extension", "prompt", "skill"

	var id: String { name }
	var displayName: String { "/\(name)" }

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
}
