import Foundation
@testable import pimux2000
import Testing

struct SidebarSessionGroupingTests {
	@Test
	func groupsSessionsByHostLocationAndCwdWhilePreservingOrderWithinEachGroup() {
		let base = Date(timeIntervalSince1970: 10_000)
		let macHost = Host(id: 1, location: "nakajima@macstudio", createdAt: base, updatedAt: base)
		let linuxHost = Host(id: 2, location: "nakajima@devbox", createdAt: base, updatedAt: base)

		let sessions = [
			makeSessionInfo(
				host: macHost,
				sessionID: "mac-app-1",
				summary: "Newest mac app session",
				cwd: "/Users/nakajima/apps/ThatApp",
				at: base.addingTimeInterval(500)
			),
			makeSessionInfo(
				host: linuxHost,
				sessionID: "linux-app-1",
				summary: "Newest linux app session",
				cwd: "/Users/nakajima/apps/ThatApp",
				at: base.addingTimeInterval(400)
			),
			makeSessionInfo(
				host: macHost,
				sessionID: "mac-app-2",
				summary: "Older mac app session",
				cwd: "/Users/nakajima/apps/ThatApp",
				at: base.addingTimeInterval(300)
			),
			makeSessionInfo(
				host: macHost,
				sessionID: "mac-other-1",
				summary: "Different mac project",
				cwd: "/Users/nakajima/apps/OtherApp",
				at: base.addingTimeInterval(200)
			),
			makeSessionInfo(
				host: macHost,
				sessionID: "mac-no-cwd",
				summary: "Missing cwd",
				cwd: nil,
				at: base.addingTimeInterval(100)
			),
		]

		let groups = sidebarSessionGroups(from: sessions)

		#expect(groups.map(\.hostLocation) == [
			"nakajima@macstudio",
			"nakajima@devbox",
			"nakajima@macstudio",
			"nakajima@macstudio",
		])
		#expect(groups.map(\.cwd) == [
			"/Users/nakajima/apps/ThatApp",
			"/Users/nakajima/apps/ThatApp",
			"/Users/nakajima/apps/OtherApp",
			nil,
		])
		#expect(groups.map { $0.sessions.map(\.session.sessionID) } == [
			["mac-app-1", "mac-app-2"],
			["linux-app-1"],
			["mac-other-1"],
			["mac-no-cwd"],
		])
	}

	@Test
	func normalizesBlankCwdsIntoTheNoWorkingDirectoryGroup() {
		let base = Date(timeIntervalSince1970: 10_000)
		let host = Host(id: 1, location: "nakajima@macstudio", createdAt: base, updatedAt: base)
		let sessions = [
			makeSessionInfo(host: host, sessionID: "blank", summary: "Blank cwd", cwd: "   ", at: base),
			makeSessionInfo(host: host, sessionID: "nil", summary: "Nil cwd", cwd: nil, at: base.addingTimeInterval(-10)),
		]

		let groups = sidebarSessionGroups(from: sessions)

		#expect(groups.count == 1)
		#expect(groups.first?.cwd == nil)
		#expect(sidebarGroupTitle(for: groups.first?.cwd) == "No working directory")
		#expect(groups.first?.sessions.map(\.session.sessionID) == ["blank", "nil"])
	}

	@Test
	func onlyShowsHostCaptionForDuplicateDisplayedCwds() {
		let groups = [
			SidebarSessionGroup(
				hostLocation: "nakajima@macstudio",
				cwd: "/Users/nakajima/apps/ThatApp",
				sessions: []
			),
			SidebarSessionGroup(
				hostLocation: "nakajima@devbox",
				cwd: "/home/nakajima/apps/ThatApp",
				sessions: []
			),
			SidebarSessionGroup(
				hostLocation: "nakajima@macstudio",
				cwd: "/Users/nakajima/apps/OtherApp",
				sessions: []
			),
		]

		let groupIDsShowingHostCaption = sidebarGroupIDsShowingHostCaption(groups)

		#expect(groupIDsShowingHostCaption.contains(groups[0].id))
		#expect(groupIDsShowingHostCaption.contains(groups[1].id))
		#expect(!groupIDsShowingHostCaption.contains(groups[2].id))
		#expect(sidebarGroupTitle(for: groups[0].cwd) == "~/apps/ThatApp")
		#expect(sidebarGroupTitle(for: groups[1].cwd) == "~/apps/ThatApp")
	}

	private func makeSessionInfo(
		host: Host,
		sessionID: String,
		summary: String,
		cwd: String?,
		at date: Date
	) -> SessionInfo {
		SessionInfo(
			session: PiSession(
				id: nil,
				hostID: host.id ?? 0,
				summary: summary,
				sessionID: sessionID,
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				cwd: cwd,
				lastMessage: nil,
				lastUserMessageAt: date,
				lastMessageAt: date,
				lastMessageRole: "assistant",
				lastReadMessageAt: date,
				isCliActive: true,
				startedAt: date.addingTimeInterval(-60),
				lastSeenAt: date
			),
			host: host
		)
	}
}
