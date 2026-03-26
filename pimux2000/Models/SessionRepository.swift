import Foundation
import Pi

struct RemotePiSession: Identifiable, Equatable {
	let record: PiSessionRecord
	var transcript: String?
	let startedAt: Date?
	let lastSeenAt: Date?

	init(record: PiSessionRecord, transcript: String? = nil) {
		self.record = record
		self.transcript = transcript
		self.startedAt = parseRemoteDate(record.startedAt)
		self.lastSeenAt = parseRemoteDate(record.lastSeenAt)
	}

	var id: String { record.sessionId }
	var pid: Int { record.pid }
	var cwd: String { record.cwd }
	var sessionFile: String? { record.sessionFile }
	var sessionId: String { record.sessionId }
	var sessionName: String? { record.sessionName }
	var model: PiModelInfo? { record.model }
	var mode: String { record.mode }
	var workSummary: String? { record.workSummary }
	var workSummaryUpdatedAt: Date? { parseRemoteDate(record.workSummaryUpdatedAt) }

	var displayName: String {
		if let workSummary, !workSummary.isEmpty {
			return workSummary
		}
		if let sessionName, !sessionName.isEmpty {
			return sessionName
		}
		return sessionId
	}

	var secondaryName: String? {
		guard let sessionName, !sessionName.isEmpty, sessionName != displayName else {
			return nil
		}
		return sessionName
	}

	var modelDescription: String {
		guard let model else { return mode }
		return "\(model.provider)/\(model.id)"
	}

	var canInteract: Bool {
		sessionFile != nil
	}

	func updatingTranscript(_ transcript: String?) -> RemotePiSession {
		RemotePiSession(record: record, transcript: transcript)
	}
}

struct LiveSessionRepository {
	func loadSessions(for sshTarget: String, allowInsecureHostKey: Bool) async throws -> [RemotePiSession] {
		let client = makeClient(for: sshTarget, allowInsecureHostKey: allowInsecureHostKey)
		return try await client.listSessions()
			.map { RemotePiSession(record: $0) }
			.sorted(by: sortSessions)
	}

	func loadTranscript(for sshTarget: String, session: RemotePiSession, allowInsecureHostKey: Bool) async throws -> String {
		let client = makeClient(for: sshTarget, allowInsecureHostKey: allowInsecureHostKey)
		let rpc = try await client.connect(to: session.record)
		defer { Task { await rpc.stop() } }
		let messages = try await rpc.getMessages()
		return formatTranscript(messages)
	}

	func send(_ text: String, to sshTarget: String, session: RemotePiSession, allowInsecureHostKey: Bool) async throws {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }

		let client = makeClient(for: sshTarget, allowInsecureHostKey: allowInsecureHostKey)
		let rpc = try await client.connect(to: session.record)
		defer { Task { await rpc.stop() } }
		_ = try await rpc.promptAndWait(trimmed)
	}

	private func makeClient(for sshTarget: String, allowInsecureHostKey: Bool) -> PiClient {
		let sshOptions = allowInsecureHostKey ? ["-o", "StrictHostKeyChecking=no"] : []
		return PiClient(configuration: .init(sshTarget: sshTarget, sshOptions: sshOptions))
	}
}

private func sortSessions(_ lhs: RemotePiSession, _ rhs: RemotePiSession) -> Bool {
	let lhsHasSummary = !(lhs.workSummary?.isEmpty ?? true)
	let rhsHasSummary = !(rhs.workSummary?.isEmpty ?? true)
	if lhsHasSummary != rhsHasSummary {
		return lhsHasSummary && !rhsHasSummary
	}

	if let lhsLastSeenAt = lhs.lastSeenAt, let rhsLastSeenAt = rhs.lastSeenAt, lhsLastSeenAt != rhsLastSeenAt {
		return lhsLastSeenAt > rhsLastSeenAt
	}

	return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
}

private func formatTranscript(_ messages: [JSONObject]) -> String {
	let lines = messages.compactMap(formatTranscriptLine)
	return lines.joined(separator: "\n\n")
}

private func formatTranscriptLine(_ message: JSONObject) -> String? {
	let role = message["role"]?.stringValue ?? ""
	switch role {
	case "user":
		let text = extractDisplayText(from: message["content"])
		return text.isEmpty ? nil : "You: \(text)"
	case "assistant":
		let text = extractDisplayText(from: message["content"])
		return text.isEmpty ? nil : "Pi: \(text)"
	case "toolResult":
		let text = extractDisplayText(from: message["content"])
		let toolName = message["toolName"]?.stringValue ?? "tool"
		return text.isEmpty ? "[\(toolName)]" : "[\(toolName)] \(text)"
	default:
		return nil
	}
}

private func extractDisplayText(from value: JSONValue?) -> String {
	guard let value else { return "" }

	if let string = value.stringValue {
		return sanitizeTranscriptText(string)
	}

	guard let items = value.arrayValue else { return "" }
	let text = items.compactMap { item -> String? in
		guard let object = item.objectValue else { return nil }
		switch object["type"]?.stringValue {
		case "text", "thinking":
			return object["text"]?.stringValue
		case "toolCall":
			if let name = object["name"]?.stringValue {
				return "[toolCall: \(name)]"
			}
			return nil
		case "image":
			return "[image]"
		default:
			return nil
		}
	}
	.joined(separator: "\n")

	return sanitizeTranscriptText(text)
}

private func sanitizeTranscriptText(_ text: String) -> String {
	text
		.trimmingCharacters(in: .whitespacesAndNewlines)
		.replacingOccurrences(of: "\r\n", with: "\n")
		.replacingOccurrences(of: "\r", with: "\n")
}

private func parseRemoteDate(_ value: String?) -> Date? {
	guard let value, !value.isEmpty else { return nil }

	let fractional = ISO8601DateFormatter()
	fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
	if let date = fractional.date(from: value) {
		return date
	}

	let plain = ISO8601DateFormatter()
	plain.formatOptions = [.withInternetDateTime]
	return plain.date(from: value)
}
