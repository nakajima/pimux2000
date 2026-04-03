import Foundation
import GRDB
@testable import pimux2000
import Testing

@MainActor
struct AppDatabaseTests {
	@Test
	func saveServerURLTrimsWhitespaceAndNormalizes() async throws {
		let database = AppDatabase.preview()
		defer { UserDefaults.standard.removeObject(forKey: "serverURL") }

		try database.saveServerURL("  localhost:3000/  ")

		#expect(UserDefaults.standard.string(forKey: "serverURL") == "http://localhost:3000")
	}

	@Test
	func changingServerURLClearsSyncedData() async throws {
		let database = AppDatabase.preview()
		defer { UserDefaults.standard.removeObject(forKey: "serverURL") }

		try database.saveServerURL("http://localhost:3000")

		try await database.dbQueue.write { db in
			var host = Host(id: nil, location: "nakajima@arch", createdAt: Date(), updatedAt: Date())
			try host.insert(db)

			var session = try PiSession(
				id: nil,
				hostID: #require(host.id),
				summary: "Old session",
				sessionID: "session-1",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastMessageAt: Date(),
				lastMessageRole: "assistant",
				startedAt: Date(),
				lastSeenAt: Date()
			)
			try session.insert(db)

			var message = try Message(piSessionID: #require(session.id), role: .assistant, toolName: nil, position: 0, createdAt: Date())
			try message.insert(db)

			var block = try MessageContentBlock(messageID: #require(message.id), type: "text", text: "hello", toolCallName: nil, position: 0)
			try block.insert(db)
		}

		try database.saveServerURL("http://localhost:4000")

		let counts = try await database.dbQueue.read { db in
			try (
				Host.fetchCount(db),
				PiSession.fetchCount(db),
				Message.fetchCount(db),
				MessageContentBlock.fetchCount(db)
			)
		}

		#expect(counts.0 == 0)
		#expect(counts.1 == 0)
		#expect(counts.2 == 0)
		#expect(counts.3 == 0)
		#expect(UserDefaults.standard.string(forKey: "serverURL") == "http://localhost:4000")
	}

	@Test
	func hostDisplayNameUsesLocation() {
		let host = Host(id: nil, location: "nakajima@arch", createdAt: Date(), updatedAt: Date())
		#expect(host.displayName == "nakajima@arch")
	}
}
