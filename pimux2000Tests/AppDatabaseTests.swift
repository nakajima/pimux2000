import Foundation
import GRDB
@testable import pimux2000
import Testing

@MainActor
struct AppDatabaseTests {
	@Test
	func saveServerConfigurationTrimsWhitespaceAndNormalizes() async throws {
		let database = AppDatabase.preview()

		try database.saveServerConfiguration(serverURL: "  localhost:3000/  ")

		let configurations = try await database.dbQueue.read { db in
			try ServerConfiguration.fetchAll(db)
		}

		#expect(configurations.count == 1)
		#expect(configurations[0].serverURL == "http://localhost:3000")
	}

	@Test
	func saveServerConfigurationKeepsSingleRow() async throws {
		let database = AppDatabase.preview()

		try database.saveServerConfiguration(serverURL: "http://localhost:3000")
		let firstConfiguration = try await database.dbQueue.read { db in
			try ServerConfiguration.fetchOne(db)
		}
		let initialUpdatedAt = try #require(firstConfiguration?.updatedAt)

		try await Task.sleep(for: .milliseconds(20))
		try database.saveServerConfiguration(serverURL: "localhost:3000")

		let configurations = try await database.dbQueue.read { db in
			try ServerConfiguration.fetchAll(db)
		}

		#expect(configurations.count == 1)
		#expect(configurations[0].serverURL == "http://localhost:3000")
		#expect(configurations[0].updatedAt >= initialUpdatedAt)
	}

	@Test
	func changingServerConfigurationClearsSyncedData() async throws {
		let database = AppDatabase.preview()
		try database.saveServerConfiguration(serverURL: "http://localhost:3000")

		try await database.dbQueue.write { db in
			var host = Host(id: nil, location: "nakajima@arch", createdAt: Date(), updatedAt: Date())
			try host.insert(db)

			var session = PiSession(
				id: nil,
				hostID: try #require(host.id),
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

			var message = Message(piSessionID: try #require(session.id), role: .assistant, toolName: nil, position: 0, createdAt: Date())
			try message.insert(db)

			var block = MessageContentBlock(messageID: try #require(message.id), type: "text", text: "hello", toolCallName: nil, position: 0)
			try block.insert(db)
		}

		try database.saveServerConfiguration(serverURL: "http://localhost:4000")

		let counts = try await database.dbQueue.read { db in
			(
				try Host.fetchCount(db),
				try PiSession.fetchCount(db),
				try Message.fetchCount(db),
				try MessageContentBlock.fetchCount(db),
				try ServerConfiguration.fetchOne(db)
			)
		}

		#expect(counts.0 == 0)
		#expect(counts.1 == 0)
		#expect(counts.2 == 0)
		#expect(counts.3 == 0)
		#expect(counts.4?.serverURL == "http://localhost:4000")
	}

	@Test
	func hostDisplayNameUsesLocation() {
		let host = Host(id: nil, location: "nakajima@arch", createdAt: Date(), updatedAt: Date())
		#expect(host.displayName == "nakajima@arch")
	}
}
