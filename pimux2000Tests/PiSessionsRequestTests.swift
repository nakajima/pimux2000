import Foundation
import GRDB
@testable import pimux2000
import Testing

struct PiSessionsRequestTests {
	@Test
	func fetchOrdersByLastUserMessageWhileKeepingActiveSessionsFirst() throws {
		let database = AppDatabase.preview()
		let base = Date(timeIntervalSince1970: 10_000)

		try database.dbQueue.write { db in
			var host = Host(
				id: nil,
				location: "nakajima@macstudio",
				createdAt: base,
				updatedAt: base
			)
			try host.insert(db)

			var inactiveNewestUser = PiSession(
				id: nil,
				hostID: try #require(host.id),
				summary: "Inactive newest user",
				sessionID: "inactive-newest-user",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastUserMessageAt: base.addingTimeInterval(300),
				lastMessageAt: base.addingTimeInterval(400),
				lastMessageRole: "assistant",
				isCliActive: false,
				startedAt: base.addingTimeInterval(-3_600),
				lastSeenAt: base.addingTimeInterval(400)
			)
			try inactiveNewestUser.insert(db)

			var activeOlderUserWithNewerAgentReply = PiSession(
				id: nil,
				hostID: try #require(host.id),
				summary: "Active older user, newer agent reply",
				sessionID: "active-older-user",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastUserMessageAt: base.addingTimeInterval(100),
				lastMessageAt: base.addingTimeInterval(500),
				lastMessageRole: "assistant",
				isCliActive: true,
				startedAt: base.addingTimeInterval(-1_800),
				lastSeenAt: base.addingTimeInterval(500)
			)
			try activeOlderUserWithNewerAgentReply.insert(db)

			var activeNewerUser = PiSession(
				id: nil,
				hostID: try #require(host.id),
				summary: "Active newer user",
				sessionID: "active-newer-user",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastUserMessageAt: base.addingTimeInterval(200),
				lastMessageAt: base.addingTimeInterval(250),
				lastMessageRole: "assistant",
				isCliActive: true,
				startedAt: base.addingTimeInterval(-900),
				lastSeenAt: base.addingTimeInterval(250)
			)
			try activeNewerUser.insert(db)
		}

		let sessions = try database.dbQueue.read { db in
			try PiSessionsRequest().fetch(db)
		}

		#expect(sessions.map(\.session.sessionID) == [
			"active-newer-user",
			"active-older-user",
			"inactive-newest-user",
		])
	}
}
