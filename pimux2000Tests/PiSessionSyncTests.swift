import Foundation
import GRDB
@testable import pimux2000
import Testing

struct PiSessionSyncTests {
	@Test
	func storePersistsHostsWithoutSessions() throws {
		let database = AppDatabase.preview()
		let remoteHostJSON = #"""
		[
			{
				"location": "nakajima@macstudio",
				"connected": false,
				"missing": true,
				"lastSeenAt": null,
				"sessions": []
			}
		]
		"""#
		let remoteHosts = try decodeHosts(from: remoteHostJSON)

		try database.dbQueue.write { db in
			try PiSessionSync.store(remoteHosts: remoteHosts, remoteSessions: [], in: db)
		}

		let hosts = try database.dbQueue.read { db in
			try Host.fetchAll(db)
		}

		#expect(hosts.count == 1)
		#expect(hosts.first?.location == "nakajima@macstudio")
	}

	@Test
	func storeDeduplicatesSessionsByStableSessionID() throws {
		let database = AppDatabase.preview()
		let createdAt = Date(timeIntervalSince1970: 10000)
		let staleSession = PimuxListedSession(
			hostLocation: "tester@host",
			hostConnected: false,
			id: "session-1",
			summary: "Stale duplicate",
			createdAt: createdAt,
			updatedAt: createdAt.addingTimeInterval(300),
			lastUserMessageAt: createdAt.addingTimeInterval(120),
			lastAssistantMessageAt: createdAt.addingTimeInterval(240),
			cwd: "/tmp/stale",
			model: "anthropic/claude-sonnet",
			contextUsage: PimuxSessionContextUsage(usedTokens: 10, maxTokens: 200_000)
		)
		let connectedSession = PimuxListedSession(
			hostLocation: "nakajima@macstudio",
			hostConnected: true,
			id: "session-1",
			summary: "Connected canonical session",
			createdAt: createdAt,
			updatedAt: createdAt.addingTimeInterval(60),
			lastUserMessageAt: createdAt.addingTimeInterval(30),
			lastAssistantMessageAt: createdAt.addingTimeInterval(45),
			cwd: "/tmp/live",
			model: "anthropic/claude-sonnet",
			contextUsage: PimuxSessionContextUsage(usedTokens: 20, maxTokens: 200_000)
		)

		try database.dbQueue.write { db in
			try PiSessionSync.store(remoteHosts: [], remoteSessions: [staleSession, connectedSession], in: db)
		}

		let (sessions, hosts) = try database.dbQueue.read { db in
			try (PiSession.fetchAll(db), Host.fetchAll(db))
		}

		#expect(sessions.count == 1)
		#expect(hosts.count == 2)

		let session = try #require(sessions.first)
		let canonicalHost = try #require(hosts.first(where: { $0.id == session.hostID }))
		#expect(canonicalHost.location == "nakajima@macstudio")
		#expect(session.summary == "Connected canonical session")
		#expect(session.cwd == "/tmp/live")
		#expect(session.contextTokensUsed == 20)
	}

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

	private func decodeHosts(from json: String) throws -> [PimuxHostSessions] {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode([PimuxHostSessions].self, from: Data(json.utf8))
	}

	private func decodeMessages(from json: String) throws -> [PimuxTranscriptMessage] {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode([PimuxTranscriptMessage].self, from: Data(json.utf8))
	}
}
