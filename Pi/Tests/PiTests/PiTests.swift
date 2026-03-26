import Foundation
@testable import Pi
import Testing

@Test func sessionRecordDecodesRegistryPayload() throws {
	let json = #"""
	{
	  "pid": 7727,
	  "cwd": "/tmp/project",
	  "sessionFile": "/tmp/session.jsonl",
	  "sessionId": "abc",
	  "sessionName": "work",
	  "model": {
	    "provider": "openai-codex",
	    "id": "gpt-5.4"
	  },
	  "startedAt": "2026-03-25T02:35:25.444Z",
	  "lastSeenAt": "2026-03-25T02:36:19.046Z",
	  "mode": "interactive",
	  "workSummary": "Implementing pi remote session CLI",
	  "workSummaryUpdatedAt": "2026-03-25T03:00:00.000Z",
	  "_registryFile": "/tmp/7727.json"
	}
	"""#

	let record = try JSONDecoder().decode(PiSessionRecord.self, from: Data(json.utf8))
	#expect(record.pid == 7727)
	#expect(record.sessionId == "abc")
	#expect(record.model == PiModelInfo(provider: "openai-codex", id: "gpt-5.4"))
	#expect(record.workSummary == "Implementing pi remote session CLI")
	#expect(record.workSummaryUpdatedAt == "2026-03-25T03:00:00.000Z")
	#expect(record.registryFile == "/tmp/7727.json")
}

@Test func resolveSessionSupportsWorkSummaryAndPrefixes() throws {
	let sessions = [
		PiSessionRecord(
			pid: 1,
			cwd: "/tmp/a",
			sessionFile: "/tmp/a.jsonl",
			sessionId: "abc12345",
			sessionName: nil,
			model: nil,
			startedAt: "",
			lastSeenAt: "",
			mode: "interactive",
			workSummary: "Implementing pi remote session CLI",
			workSummaryUpdatedAt: nil,
			lastMessage: nil,
			lastMessageAt: nil,
			lastMessageRole: nil,
			registryFile: nil
		),
		PiSessionRecord(
			pid: 2,
			cwd: "/tmp/b",
			sessionFile: "/tmp/b.jsonl",
			sessionId: "def67890",
			sessionName: nil,
			model: nil,
			startedAt: "",
			lastSeenAt: "",
			mode: "interactive",
			workSummary: "Fixing SSH RPC session switching",
			workSummaryUpdatedAt: nil,
			lastMessage: nil,
			lastMessageAt: nil,
			lastMessageRole: nil,
			registryFile: nil
		),
	]

	#expect(try PiClient.resolveSession(identifier: "abc12345", from: sessions).sessionId == "abc12345")
	#expect(try PiClient.resolveSession(identifier: "abc", from: sessions).sessionId == "abc12345")
	#expect(try PiClient.resolveSession(identifier: "Fixing SSH RPC", from: sessions).sessionId == "def67890")
}

@Test func hostConfigurationTreatsLoopbackHostsAsLocalByDefault() {
	#expect(PiHostConfiguration(sshTarget: "localhost").executesLocally)
	#expect(PiHostConfiguration(sshTarget: "127.0.0.1").executesLocally)
	#expect(PiHostConfiguration(sshTarget: "::1").executesLocally)
	#expect(!PiHostConfiguration(sshTarget: "example.com").executesLocally)
	#expect(!PiHostConfiguration(sshTarget: "localhost", executesLocally: false).executesLocally)
	#expect(PiHostConfiguration.local().executesLocally)
}

@Test func listSessionsWorksWithoutSSHForLoopbackHosts() async throws {
	let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: tempDirectory) }

	let registryFile = tempDirectory.appendingPathComponent("1234.json")
	try """
	{
	  "pid": 1234,
	  "cwd": "/tmp/project",
	  "sessionFile": "/tmp/session.jsonl",
	  "sessionId": "local-session",
	  "sessionName": "local",
	  "model": null,
	  "startedAt": "2026-03-25T02:35:25.444Z",
	  "lastSeenAt": "2026-03-25T02:36:19.046Z",
	  "mode": "interactive",
	  "workSummary": "Testing localhost transport",
	  "workSummaryUpdatedAt": null
	}
	""".write(to: registryFile, atomically: true, encoding: .utf8)

	let client = PiClient(configuration: .init(
		sshTarget: "localhost",
		remoteRegistryDirectory: tempDirectory.path
	))

	let sessions = try await client.listSessions()
	#expect(sessions.count == 1)
	#expect(sessions.first?.sessionId == "local-session")
	#expect(sessions.first?.registryFile == registryFile.path)
}

@Test func jsonValueRoundTripsNestedPayloads() throws {
	let original: JSONValue = .object([
		"type": .string("response"),
		"success": .bool(true),
		"data": .object([
			"count": .number(3),
			"items": .array([
				.string("a"),
				.null,
				.object(["ok": .bool(true)]),
			]),
		]),
	])

	let encoded = try JSONEncoder().encode(original)
	let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
	#expect(decoded == original)
}
