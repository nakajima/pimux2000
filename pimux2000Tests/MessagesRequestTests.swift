import Foundation
import GRDB
@testable import pimux2000
import Testing

struct MessagesRequestTests {
	@Test
	func fetchUsesStableSessionIDInsteadOfStaleRowID() throws {
		let database = AppDatabase.preview()
		let stableSessionID = "session-1"

		try database.dbQueue.write { db in
			var host = Host(id: nil, location: "nakajima@macstudio", createdAt: Date(), updatedAt: Date())
			try host.insert(db)

			var oldSession = PiSession(
				id: nil,
				hostID: host.id!,
				summary: "Old session row",
				sessionID: stableSessionID,
				sessionFile: nil,
				model: "anthropic/claude-opus-4-6",
				lastMessage: nil,
				lastMessageAt: nil,
				lastMessageRole: nil,
				startedAt: Date(),
				lastSeenAt: Date()
			)
			try oldSession.insert(db)

			var oldMessage = Message(
				piSessionID: oldSession.id!,
				role: .assistant,
				toolName: nil,
				position: 0,
				createdAt: Date()
			)
			try oldMessage.insert(db)
			var oldBlock = MessageContentBlock(
				messageID: oldMessage.id!,
				type: "text",
				text: "old",
				toolCallName: nil,
				position: 0
			)
			try oldBlock.insert(db)

			try oldSession.delete(db)

			var newSession = PiSession(
				id: nil,
				hostID: host.id!,
				summary: "New session row",
				sessionID: stableSessionID,
				sessionFile: nil,
				model: "anthropic/claude-opus-4-6",
				lastMessage: nil,
				lastMessageAt: nil,
				lastMessageRole: nil,
				startedAt: Date(),
				lastSeenAt: Date()
			)
			try newSession.insert(db)

			var newMessage = Message(
				piSessionID: newSession.id!,
				role: .assistant,
				toolName: nil,
				position: 0,
				createdAt: Date()
			)
			try newMessage.insert(db)
			var newBlock = MessageContentBlock(
				messageID: newMessage.id!,
				type: "text",
				text: "new",
				toolCallName: nil,
				position: 0
			)
			try newBlock.insert(db)
		}

		let messages = try database.dbQueue.read { db in
			try MessagesRequest(sessionID: stableSessionID).fetch(db)
		}

		#expect(messages.count == 1)
		#expect(messages.first?.contentBlocks.first?.text == "new")
	}

	@Test
	func dbUniqueIndexPreventsDuplicateServerMessageIDs() throws {
		let database = AppDatabase.preview()

		try database.dbQueue.write { db in
			var host = Host(id: nil, location: "nakajima@macstudio", createdAt: Date(), updatedAt: Date())
			try host.insert(db)

			var session = PiSession(
				id: nil,
				hostID: host.id!,
				summary: "Session row",
				sessionID: "session-1",
				sessionFile: nil,
				model: "anthropic/claude-opus-4-6",
				lastMessage: nil,
				lastMessageAt: nil,
				lastMessageRole: nil,
				startedAt: Date(),
				lastSeenAt: Date()
			)
			try session.insert(db)

			var message = Message(
				piSessionID: session.id!,
				serverMessageID: "msg-1",
				role: .assistant,
				toolName: nil,
				position: 0,
				createdAt: Date()
			)
			try message.insert(db)

			// The unique index on (piSessionID, serverMessageID) should prevent duplicates.
			var duplicate = Message(
				piSessionID: session.id!,
				serverMessageID: "msg-1",
				role: .assistant,
				toolName: nil,
				position: 1,
				createdAt: Date()
			)
			#expect(throws: (any Error).self) {
				try duplicate.insert(db)
			}
		}
	}
}
