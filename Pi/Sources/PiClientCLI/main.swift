import Foundation
import Pi

@main
struct PiClientCLI {
	static func main() async {
		do {
			let cli = try CLI(arguments: Array(CommandLine.arguments.dropFirst()))
			try await cli.run()
		} catch let error as CLIError {
			fputs("error: \(error.localizedDescription)\n", stderr)
			if case .usage = error {
				fputs("\n\(CLI.help)\n", stderr)
			}
			Foundation.exit(2)
		} catch {
			fputs("error: \(error.localizedDescription)\n", stderr)
			Foundation.exit(1)
		}
	}
}

private struct CLI {
	let command: Command

	init(arguments: [String]) throws {
		self.command = try Command.parse(arguments)
	}

	func run() async throws {
		switch command {
		case .help:
			print(Self.help)
		case let .list(server):
			let client = try await connect(to: server)
			let sessions = try await client.listSessions()
			await client.disconnect()

			if sessions.isEmpty {
				print("No active pi sessions")
				return
			}

			for (index, session) in sessions.enumerated() {
				if index > 0 { print("") }
				print("sessionId: \(session["sessionId"]?.stringValue ?? "-")")
				print("workSummary: \(session["workSummary"]?.stringValue ?? "-")")
				print("sessionName: \(session["sessionName"]?.stringValue ?? "-")")
				print("pid: \(session["pid"]?.intValue.map(String.init) ?? "-")")
				print("cwd: \(session["cwd"]?.stringValue ?? "-")")
				print("mode: \(session["mode"]?.stringValue ?? "-")")
				print("model: \(formattedModel(session["model"]?.objectValue))")
				print("startedAt: \(session["startedAt"]?.stringValue ?? "-")")
				print("lastSeenAt: \(session["lastSeenAt"]?.stringValue ?? "-")")
				print("sessionFile: \(session["sessionFile"]?.stringValue ?? "-")")
			}
		case let .state(server, sessionID):
			let client = try await connect(to: server)
			let state = try await client.getState(sessionId: sessionID)
			await client.disconnect()

			guard let state else {
				print("Session not found: \(sessionID)")
				return
			}

			printKeyValue(from: state, keys: [
				"sessionId",
				"sessionFile",
				"mode",
				"lastMessage",
				"lastMessageAt",
				"lastMessageRole",
				"startedAt",
				"lastSeenAt",
			])
		case let .messages(server, sessionIdentifier):
			let client = try await connect(to: server)
			let sessionFile = try await resolveSessionFile(client: client, identifier: sessionIdentifier)
			let messages = try await client.getMessages(sessionFile: sessionFile)
			await client.disconnect()

			print("messageCount: \(messages.count)")
			for (index, message) in messages.enumerated() {
				print("")
				print("[\(index)] role=\(message["role"]?.stringValue ?? "unknown")")
				if let toolName = message["toolName"]?.stringValue {
					print("toolName: \(toolName)")
				}
				if let summary = summarize(message: message) {
					print(summary)
				}
			}
		case let .last(server, sessionIdentifier):
			let client = try await connect(to: server)
			let sessionFile = try await resolveSessionFile(client: client, identifier: sessionIdentifier)
			let text = try await client.getLastAssistantText(sessionFile: sessionFile)
			await client.disconnect()
			print(text ?? "")
		case let .prompt(server, sessionIdentifier, message):
			let client = try await connect(to: server)
			let sessionFile = try await resolveSessionFile(client: client, identifier: sessionIdentifier)
			let result = try await client.prompt(sessionFile: sessionFile, message: message)
			await client.disconnect()

			if let events = result["events"]?.arrayValue {
				print("eventCount: \(events.count)")
			}
		}
	}

	private func connect(to server: String) async throws -> PiServerClient {
		var url = server
		if !url.hasPrefix("ws://") && !url.hasPrefix("wss://") {
			// Bare host or host:port — assume ws://
			if url.contains("://") {
				throw CLIError.invalidServer(url)
			}
			url = "ws://\(url)"
			if !url.contains(":7749") && url.split(separator: ":").count < 3 {
				url += ":7749"
			}
		}
		let client = PiServerClient(serverURL: url)
		try await client.connect()
		return client
	}

	private func resolveSessionFile(client: PiServerClient, identifier: String) async throws -> String {
		let sessions = try await client.listSessions()

		// Exact session ID match
		if let match = sessions.first(where: { $0["sessionId"]?.stringValue == identifier }) {
			guard let file = match["sessionFile"]?.stringValue else {
				throw CLIError.noSessionFile(identifier)
			}
			return file
		}

		// Prefix match on session ID
		let prefixMatches = sessions.filter { $0["sessionId"]?.stringValue?.hasPrefix(identifier) == true }
		if prefixMatches.count == 1, let file = prefixMatches[0]["sessionFile"]?.stringValue {
			return file
		}

		// Substring match on workSummary
		let needle = identifier.lowercased()
		let summaryMatches = sessions.filter {
			$0["workSummary"]?.stringValue?.lowercased().contains(needle) == true
		}
		if summaryMatches.count == 1, let file = summaryMatches[0]["sessionFile"]?.stringValue {
			return file
		}

		if prefixMatches.count > 1 || summaryMatches.count > 1 {
			throw CLIError.ambiguous(identifier)
		}

		throw CLIError.notFound(identifier)
	}

	static let help = """
	Usage:
	  pi-client list <server-url>
	  pi-client state <server-url> <session-id>
	  pi-client messages <server-url> <session-id-or-summary>
	  pi-client prompt <server-url> <session-id-or-summary> <message>
	  pi-client last <server-url> <session-id-or-summary>
	  pi-client help

	Examples:
	  pi-client list ws://localhost:7749
	  pi-client messages ws://myserver:7749 chat-ui
	"""
}

private enum Command {
	case help
	case list(String)
	case state(String, String)
	case messages(String, String)
	case prompt(String, String, String)
	case last(String, String)

	static func parse(_ arguments: [String]) throws -> Command {
		guard let command = arguments.first else { return .help }

		switch command {
		case "help", "--help", "-h":
			return .help
		case "list":
			guard arguments.count == 2 else { throw CLIError.usage }
			return .list(arguments[1])
		case "state":
			guard arguments.count == 3 else { throw CLIError.usage }
			return .state(arguments[1], arguments[2])
		case "messages":
			guard arguments.count == 3 else { throw CLIError.usage }
			return .messages(arguments[1], arguments[2])
		case "last":
			guard arguments.count == 3 else { throw CLIError.usage }
			return .last(arguments[1], arguments[2])
		case "prompt":
			guard arguments.count >= 4 else { throw CLIError.usage }
			return .prompt(arguments[1], arguments[2], arguments.dropFirst(3).joined(separator: " "))
		default:
			throw CLIError.unknownCommand(command)
		}
	}
}

private enum CLIError: LocalizedError {
	case usage
	case unknownCommand(String)
	case notFound(String)
	case ambiguous(String)
	case noSessionFile(String)
	case invalidServer(String)

	var errorDescription: String? {
		switch self {
		case .usage:
			return "invalid arguments"
		case let .unknownCommand(command):
			return "unknown command: \(command)"
		case let .notFound(id):
			return "no session found for: \(id)"
		case let .ambiguous(id):
			return "ambiguous session identifier: \(id)"
		case let .noSessionFile(id):
			return "session \(id) has no session file"
		case let .invalidServer(url):
			return "invalid server URL: \(url) (expected ws://host:port)"
		}
	}
}

private func formattedModel(_ model: JSONObject?) -> String {
	guard let model else { return "-" }
	let provider = model["provider"]?.stringValue ?? ""
	let id = model["id"]?.stringValue ?? ""
	return "\(provider)/\(id)"
}

private func printKeyValue(from object: JSONObject, keys: [String]) {
	for key in keys {
		guard let value = object[key] else { continue }
		print("\(key): \(stringify(value))")
	}
}

private func stringify(_ value: JSONValue) -> String {
	switch value {
	case let .string(value): return value
	case let .number(value):
		if let int = Int(exactly: value) { return String(int) }
		return String(value)
	case let .bool(value): return String(value)
	case .null: return "null"
	case let .array(value): return "[\(value.count) items]"
	case let .object(value): return "{\(value.count) keys}"
	}
}

private func summarize(message: JSONObject) -> String? {
	guard let content = message["content"]?.arrayValue else { return nil }
	var parts: [String] = []

	for item in content {
		guard let object = item.objectValue else { continue }
		switch object["type"]?.stringValue {
		case "text", "thinking":
			if let text = object["text"]?.stringValue, !text.isEmpty {
				parts.append(text)
			}
		case "toolCall":
			let name = object["name"]?.stringValue ?? "tool"
			parts.append("[toolCall: \(name)]")
		case "image":
			parts.append("[image]")
		default:
			continue
		}
	}

	guard !parts.isEmpty else { return nil }
	let joined = parts.joined(separator: " ")
	let singleLine = joined.replacingOccurrences(of: "\n", with: " ")
	if singleLine.count <= 240 {
		return "content: \(singleLine)"
	}
	let end = singleLine.index(singleLine.startIndex, offsetBy: 240)
	return "content: \(singleLine[..<end])..."
}
