import Foundation
import GRDB

enum UITestFixtures {
	static func install(in appDatabase: AppDatabase) throws {
		try appDatabase.saveServerConfiguration(serverURL: "http://fixture.local:3000")

		try appDatabase.dbQueue.write { db in
			let now = Date()

			var host = Host(id: nil, location: "demo@fixture", createdAt: now, updatedAt: now)
			try host.insert(db)
			let hostID = try db.require(host.id)

			var shellSession = PiSession(
				id: nil,
				hostID: hostID,
				summary: "Shell session health",
				sessionID: "fixture-shell-session",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastUserMessageAt: now.addingTimeInterval(-60),
				lastMessageAt: now,
				lastMessageRole: "assistant",
				lastReadMessageAt: now,
				startedAt: now.addingTimeInterval(-600),
				lastSeenAt: now
			)
			try shellSession.insert(db)
			let shellSessionID = try db.require(shellSession.id)

			var shellUserMessage = Message(
				piSessionID: shellSessionID,
				role: .user,
				toolName: nil,
				position: 0,
				createdAt: now.addingTimeInterval(-60)
			)
			try shellUserMessage.insert(db)
			var shellUserBlock = try MessageContentBlock(
				messageID: db.require(shellUserMessage.id),
				type: "text",
				text: "Run the health check against the fixture shell.",
				toolCallName: nil,
				position: 0
			)
			try shellUserBlock.insert(db)

			var shellAssistantMessage = Message(
				piSessionID: shellSessionID,
				role: .assistant,
				toolName: nil,
				position: 1,
				createdAt: now.addingTimeInterval(-30)
			)
			try shellAssistantMessage.insert(db)
			var shellAssistantBlock = try MessageContentBlock(
				messageID: db.require(shellAssistantMessage.id),
				type: "text",
				text: "Everything looks healthy from the fixture transcript.",
				toolCallName: nil,
				position: 0
			)
			try shellAssistantBlock.insert(db)

			var logsSession = PiSession(
				id: nil,
				hostID: hostID,
				summary: "Watching logs",
				sessionID: "fixture-logs-session",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastUserMessageAt: now.addingTimeInterval(-180),
				lastMessageAt: now.addingTimeInterval(-120),
				lastMessageRole: "assistant",
				lastReadMessageAt: now.addingTimeInterval(-120),
				startedAt: now.addingTimeInterval(-1200),
				lastSeenAt: now.addingTimeInterval(-120)
			)
			try logsSession.insert(db)
		}
	}
}

private extension Database {
	func require<T>(_ value: T?) throws -> T {
		guard let value else {
			throw DatabaseError(message: "Expected fixture value to be present")
		}
		return value
	}
}
