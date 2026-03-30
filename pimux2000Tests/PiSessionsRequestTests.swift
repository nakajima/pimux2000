import Foundation
import GRDB
@testable import pimux2000
import Testing

struct PiSessionsRequestTests {
	@Test
	func fetchOrdersActiveSessionsBeforeInactiveSessions() throws {
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

			var inactiveMostRecent = PiSession(
				id: nil,
				hostID: try #require(host.id),
				summary: "Inactive newest",
				sessionID: "inactive-newest",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastMessageAt: base.addingTimeInterval(300),
				lastMessageRole: "assistant",
				isCliActive: false,
				startedAt: base.addingTimeInterval(-3_600),
				lastSeenAt: base.addingTimeInterval(300)
			)
			try inactiveMostRecent.insert(db)

			var activeMoreRecent = PiSession(
				id: nil,
				hostID: try #require(host.id),
				summary: "Active newer",
				sessionID: "active-newer",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastMessageAt: base.addingTimeInterval(200),
				lastMessageRole: "assistant",
				isCliActive: true,
				startedAt: base.addingTimeInterval(-1_800),
				lastSeenAt: base.addingTimeInterval(200)
			)
			try activeMoreRecent.insert(db)

			var activeOlder = PiSession(
				id: nil,
				hostID: try #require(host.id),
				summary: "Active older",
				sessionID: "active-older",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				lastMessage: nil,
				lastMessageAt: base.addingTimeInterval(100),
				lastMessageRole: "assistant",
				isCliActive: true,
				startedAt: base.addingTimeInterval(-900),
				lastSeenAt: base.addingTimeInterval(100)
			)
			try activeOlder.insert(db)
		}

		let sessions = try database.dbQueue.read { db in
			try PiSessionsRequest().fetch(db)
		}

		#expect(sessions.map(\.session.sessionID) == [
			"active-newer",
			"active-older",
			"inactive-newest",
		])
	}
}
