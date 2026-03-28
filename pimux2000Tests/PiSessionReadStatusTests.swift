import Foundation
import GRDB
@testable import pimux2000
import Testing

struct PiSessionReadStatusTests {
	@Test
	func storeInitializesNewSessionsAsRead() throws {
		let database = AppDatabase.preview()
		let createdAt = Date(timeIntervalSince1970: 1_000)
		let lastUserMessageAt = createdAt.addingTimeInterval(60)
		let lastAssistantMessageAt = createdAt.addingTimeInterval(120)
		let updatedAt = createdAt.addingTimeInterval(180)

		let remoteSession = PimuxListedSession(
			hostLocation: "nakajima@macstudio",
			id: "session-1",
			summary: "Read status",
			createdAt: createdAt,
			updatedAt: updatedAt,
			lastUserMessageAt: lastUserMessageAt,
			lastAssistantMessageAt: lastAssistantMessageAt,
			cwd: "/Users/nakajima/apps/pimux2000",
			model: "anthropic/claude-sonnet"
		)

		try database.dbQueue.write { db in
			try PiSessionSync.store(remoteHosts: [], remoteSessions: [remoteSession], in: db)
		}

		let session = try database.dbQueue.read { db in
			try PiSession.fetchOne(db)
		}

		#expect(session?.lastMessageAt == lastAssistantMessageAt)
		#expect(session?.lastReadMessageAt == lastAssistantMessageAt)
		#expect(session?.lastMessageRole == "assistant")
		#expect(session?.isUnread == false)
	}

	@Test
	func storePreservesReadMarkerWhenNewMessagesArrive() throws {
		let database = AppDatabase.preview()
		let createdAt = Date(timeIntervalSince1970: 2_000)
		let firstAssistantMessageAt = createdAt.addingTimeInterval(60)
		let secondAssistantMessageAt = createdAt.addingTimeInterval(180)

		let initialRemoteSession = PimuxListedSession(
			hostLocation: "nakajima@macstudio",
			id: "session-1",
			summary: "Read status",
			createdAt: createdAt,
			updatedAt: createdAt.addingTimeInterval(90),
			lastUserMessageAt: createdAt.addingTimeInterval(30),
			lastAssistantMessageAt: firstAssistantMessageAt,
			cwd: "/Users/nakajima/apps/pimux2000",
			model: "anthropic/claude-sonnet"
		)

		let updatedRemoteSession = PimuxListedSession(
			hostLocation: "nakajima@macstudio",
			id: "session-1",
			summary: "Read status",
			createdAt: createdAt,
			updatedAt: createdAt.addingTimeInterval(210),
			lastUserMessageAt: createdAt.addingTimeInterval(30),
			lastAssistantMessageAt: secondAssistantMessageAt,
			cwd: "/Users/nakajima/apps/pimux2000",
			model: "anthropic/claude-sonnet"
		)

		try database.dbQueue.write { db in
			try PiSessionSync.store(remoteHosts: [], remoteSessions: [initialRemoteSession], in: db)
		}

		try database.dbQueue.write { db in
			try PiSessionSync.store(remoteHosts: [], remoteSessions: [updatedRemoteSession], in: db)
		}

		let session = try database.dbQueue.read { db in
			try PiSession.fetchOne(db)
		}

		#expect(session?.lastReadMessageAt == firstAssistantMessageAt)
		#expect(session?.lastMessageAt == secondAssistantMessageAt)
		#expect(session?.isUnread == true)
	}

	@Test
	func markSessionReadAdvancesButDoesNotMoveBackward() throws {
		let database = AppDatabase.preview()
		let createdAt = Date(timeIntervalSince1970: 3_000)
		let firstMessageAt = createdAt.addingTimeInterval(60)
		let latestMessageAt = createdAt.addingTimeInterval(180)

		try database.dbQueue.write { db in
			var host = Host(
				id: nil,
				location: "nakajima@macstudio",
				createdAt: createdAt,
				updatedAt: latestMessageAt
			)
			try host.insert(db)

			var session = PiSession(
				id: nil,
				hostID: try #require(host.id),
				summary: "Read status",
				sessionID: "session-1",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastMessageAt: latestMessageAt,
				lastMessageRole: "assistant",
				lastReadMessageAt: firstMessageAt,
				startedAt: createdAt,
				lastSeenAt: latestMessageAt
			)
			try session.insert(db)
		}

		try database.markSessionRead(sessionID: "session-1", through: latestMessageAt)

		let afterAdvancing = try database.dbQueue.read { db in
			try PiSession.fetchOne(db)
		}
		#expect(afterAdvancing?.lastReadMessageAt == latestMessageAt)
		#expect(afterAdvancing?.isUnread == false)

		try database.markSessionRead(sessionID: "session-1", through: firstMessageAt)

		let afterOlderWrite = try database.dbQueue.read { db in
			try PiSession.fetchOne(db)
		}
		#expect(afterOlderWrite?.lastReadMessageAt == latestMessageAt)
	}
}
