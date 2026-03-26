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
		case let .list(host):
			let client = PiClient(configuration: .init(sshTarget: host))
			let sessions = try await client.listSessions()
			if sessions.isEmpty {
				print("No active pi sessions on \(host)")
				return
			}

			for (index, session) in sessions.enumerated() {
				if index > 0 { print("") }
				print("sessionId: \(session.sessionId)")
				print("workSummary: \(session.workSummary ?? "-")")
				print("name: \(session.sessionName ?? "-")")
				print("pid: \(session.pid)")
				print("cwd: \(session.cwd)")
				print("mode: \(session.mode)")
				print("model: \(formattedModel(session.model))")
				print("startedAt: \(session.startedAt)")
				print("lastSeenAt: \(session.lastSeenAt)")
				print("workSummaryUpdatedAt: \(session.workSummaryUpdatedAt ?? "-")")
				print("sessionFile: \(session.sessionFile ?? "-")")
			}
		case let .state(host, sessionID):
			let client = PiClient(configuration: .init(sshTarget: host))
			let rpc = try await client.connect(sessionId: sessionID)
			defer { Task { await rpc.stop() } }
			let state = try await rpc.getState()
			print("sessionId: \(state.sessionId ?? "-")")
			print("sessionName: \(state.sessionName ?? "-")")
			print("sessionFile: \(state.sessionFile ?? "-")")
			print("isStreaming: \(state.isStreaming.map(String.init) ?? "-")")
			printKeyValue(from: state.raw, keys: [
				"thinkingLevel",
				"isCompacting",
				"steeringMode",
				"followUpMode",
				"autoCompactionEnabled",
				"messageCount",
				"pendingMessageCount",
			])
		case let .messages(host, sessionID):
			let client = PiClient(configuration: .init(sshTarget: host))
			let rpc = try await client.connect(sessionId: sessionID)
			defer { Task { await rpc.stop() } }
			let messages = try await rpc.getMessages()
			print("messageCount: \(messages.count)")
			for (index, message) in messages.enumerated() {
				print("")
				print("[\(index)] role=\(message["role"]?.stringValue ?? "unknown")")
				if let toolName = message["toolName"]?.stringValue {
					print("toolName: \(toolName)")
				}
				if let toolCallId = message["toolCallId"]?.stringValue {
					print("toolCallId: \(toolCallId)")
				}
				if let summary = summarize(message: message) {
					print(summary)
				}
			}
		case let .last(host, sessionID):
			let client = PiClient(configuration: .init(sshTarget: host))
			let rpc = try await client.connect(sessionId: sessionID)
			defer { Task { await rpc.stop() } }
			try print(await rpc.getLastAssistantText() ?? "")
		case let .prompt(host, sessionID, message):
			let client = PiClient(configuration: .init(sshTarget: host))
			let rpc = try await client.connect(sessionId: sessionID)
			defer { Task { await rpc.stop() } }
			let events = try await rpc.promptAndWait(message)
			print("eventCount: \(events.count)")
			print("")
			try print(await rpc.getLastAssistantText() ?? "")
		}
	}

	static let help = """
	Usage:
	  pi-client list <host>
	  pi-client state <host> <session-id-or-work-summary>
	  pi-client messages <host> <session-id-or-work-summary>
	  pi-client prompt <host> <session-id-or-work-summary> <message>
	  pi-client last <host> <session-id-or-work-summary>
	  pi-client help

	Notes:
	  Use localhost, 127.0.0.1, or ::1 to talk to the local pi runtime without SSH.
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

	var errorDescription: String? {
		switch self {
		case .usage:
			return "invalid arguments"
		case let .unknownCommand(command):
			return "unknown command: \(command)"
		}
	}
}

private func formattedModel(_ model: PiModelInfo?) -> String {
	guard let model else { return "-" }
	return "\(model.provider)/\(model.id)"
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
