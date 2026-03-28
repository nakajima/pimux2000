import Foundation
import GRDB
@testable import pimux2000
import Testing

struct PiSessionSyncTests {
	@Test
	func storeMessagesPreservesThinkingAndToolCallBlocks() throws {
		let database = AppDatabase.preview()
		let remoteMessages = try decodeMessages(from: #"""
		[
			{
				"created_at": "2026-03-28T06:20:00Z",
				"role": "assistant",
				"body": "Final answer",
				"blocks": [
					{ "type": "thinking", "text": "Reasoning through the plan" },
					{ "type": "text", "text": "Final answer" },
					{ "type": "toolCall", "toolCallName": "bash" }
				]
			}
		]
		"""#)

		let stableSessionID = "session-1"
		try database.dbQueue.write { db in
			var host = Host(id: nil, location: "nakajima@macstudio", createdAt: Date(), updatedAt: Date())
			try host.insert(db)

			var session = PiSession(
				id: nil,
				hostID: host.id!,
				summary: "Streaming session",
				sessionID: stableSessionID,
				sessionFile: nil,
				model: "openai-codex/gpt-5.4",
				lastMessage: nil,
				lastMessageAt: Date(),
				lastMessageRole: "assistant",
				startedAt: Date(),
				lastSeenAt: Date()
			)
			try session.insert(db)

			try PiSessionSync.storeMessages(remoteMessages, piSessionID: session.id!, in: db)
		}

		let messages = try database.dbQueue.read { db in
			try MessagesRequest(sessionID: stableSessionID).fetch(db)
		}

		#expect(messages.count == 1)
		#expect(messages[0].contentBlocks.count == 3)
		#expect(messages[0].contentBlocks[0].type == "thinking")
		#expect(messages[0].contentBlocks[0].text == "Reasoning through the plan")
		#expect(messages[0].contentBlocks[1].type == "text")
		#expect(messages[0].contentBlocks[1].text == "Final answer")
		#expect(messages[0].contentBlocks[2].type == "toolCall")
		#expect(messages[0].contentBlocks[2].toolCallName == "bash")
	}

	private func decodeMessages(from json: String) throws -> [PimuxTranscriptMessage] {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode([PimuxTranscriptMessage].self, from: Data(json.utf8))
	}
}
