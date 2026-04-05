import GRDB
import GRDBQuery
import SwiftUI

struct SidebarView: View {
	@Environment(\.databaseContext) private var dbContext
	@Environment(\.pimuxServerClient) private var pimuxServerClient
	@Query(PiSessionsRequest()) private var sessions: [SessionInfo]
	@AppStorage("serverURL") private var serverURL: String?
	@Binding var selectedSessionID: String?
	@State private var isShowingServerSheet = false
	@State private var isShowingSettings = false
	@State private var collapsedGroupIDs: Set<String> = []

	private var groupedSessions: [SidebarSessionGroup] {
		sidebarSessionGroups(from: sessions)
	}

	private var groupIDsShowingHostCaption: Set<String> {
		sidebarGroupIDsShowingHostCaption(groupedSessions)
	}

	var body: some View {
		List(selection: $selectedSessionID) {
			if sessions.isEmpty {
				Text("No recent sessions")
					.foregroundStyle(.secondary)
			} else {
				ForEach(groupedSessions) { group in
					DisclosureGroup(isExpanded: isExpandedBinding(for: group.id)) {
						ForEach(group.sessions, id: \.session.sessionID) { sessionInfo in
							HStack(alignment: .top, spacing: 12) {
								VStack(alignment: .leading, spacing: 4) {
									Text(verbatim: sessionInfo.session.summary)
									HStack {
										if let lastMessageAt = sessionInfo.session.lastMessageAt {
											Text(verbatim: lastMessageAt.formatted(.dateTime))
										}

										Spacer()

										if sessionInfo.session.isUnread && selectedSessionID != sessionInfo.session.sessionID {
											UnreadSessionBadge()
										}
									}
									.font(.caption)
									.foregroundStyle(.secondary)
								}
							}
							.tag(sessionInfo.session.sessionID)
							.contentShape(Rectangle())
							.onTapGesture {
								selectedSessionID = sessionInfo.session.sessionID
							}
						}
					} label: {
						SidebarGroupHeaderLabel(
							cwdTitle: sidebarGroupTitle(for: group.cwd),
							hostLocation: group.hostLocation,
							showsHostCaption: groupIDsShowingHostCaption.contains(group.id)
						)
					}
				}
			}
		}
		.refreshable {
			guard let pimuxServerClient else { return }
			let syncer = PiSessionSync(dbContext: dbContext, pimuxServerClient: pimuxServerClient)
			await syncer.sync()
		}
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					isShowingServerSheet = true
				} label: {
					Label(pimuxServerClient == nil ? "Connect Server" : "Server", systemImage: "server.rack")
				}
			}
			#if os(iOS)
				ToolbarItem(placement: .bottomBar) {
					Button { isShowingSettings = true } label: {
						Label("Settings", systemImage: "gearshape")
					}
				}
			#else
				ToolbarItem {
					Button { isShowingSettings = true } label: {
						Label("Settings", systemImage: "gearshape")
					}
				}
			#endif
		}
		.sheet(isPresented: $isShowingServerSheet) {
			ServerConnectionSheet(initialServerURL: serverURL ?? "")
		}
		.sheet(isPresented: $isShowingSettings) {
			NavigationStack {
				FontPickerView()
					.toolbar {
						ToolbarItem(placement: .confirmationAction) {
							Button("Done") { isShowingSettings = false }
						}
					}
			}
		}
	}

	private func isExpandedBinding(for groupID: String) -> Binding<Bool> {
		Binding(
			get: { !collapsedGroupIDs.contains(groupID) },
			set: { isExpanded in
				if isExpanded {
					collapsedGroupIDs.remove(groupID)
				} else {
					collapsedGroupIDs.insert(groupID)
				}
			}
		)
	}
}

struct SidebarSessionGroup: Identifiable, Equatable {
	let hostLocation: String
	let cwd: String?
	let sessions: [SessionInfo]

	var id: String {
		"\(hostLocation)\u{1F}\(cwd ?? "")"
	}
}

func sidebarSessionGroups(from sessions: [SessionInfo]) -> [SidebarSessionGroup] {
	var orderedKeys: [SidebarSessionGroupKey] = []
	var groupedSessions: [SidebarSessionGroupKey: [SessionInfo]] = [:]

	for sessionInfo in sessions {
		let key = SidebarSessionGroupKey(
			hostLocation: sessionInfo.host.location,
			cwd: normalizedSidebarCwd(sessionInfo.session.cwd)
		)

		if groupedSessions[key] == nil {
			orderedKeys.append(key)
		}

		groupedSessions[key, default: []].append(sessionInfo)
	}

	return orderedKeys.map { key in
		SidebarSessionGroup(
			hostLocation: key.hostLocation,
			cwd: key.cwd,
			sessions: groupedSessions[key] ?? []
		)
	}
}

private struct SidebarSessionGroupKey: Hashable {
	let hostLocation: String
	let cwd: String?
}

func normalizedSidebarCwd(_ cwd: String?) -> String? {
	guard let cwd else { return nil }
	let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
	return trimmed.isEmpty ? nil : trimmed
}

func sidebarDisplayCwd(_ cwd: String) -> String {
	cwd.replacing(/\/Users\/\w+\/|\/home\/\w+\//, with: "~/")
}

func sidebarGroupTitle(for cwd: String?) -> String {
	guard let cwd else { return "No working directory" }
	return sidebarDisplayCwd(cwd)
}

func sidebarGroupIDsShowingHostCaption(_ groups: [SidebarSessionGroup]) -> Set<String> {
	let titleCounts = Dictionary(grouping: groups, by: { sidebarGroupTitle(for: $0.cwd) })
		.mapValues(\.count)

	return Set(
		groups
			.filter { titleCounts[sidebarGroupTitle(for: $0.cwd), default: 0] > 1 }
			.map(\.id)
	)
}

private struct SidebarGroupHeaderLabel: View {
	let cwdTitle: String
	let hostLocation: String
	let showsHostCaption: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: showsHostCaption ? 1 : 0) {
			Text(verbatim: cwdTitle)
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.primary)
				.lineLimit(1)
				.truncationMode(.middle)

			if showsHostCaption {
				Text(verbatim: hostLocation)
					.font(.caption2)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.vertical, showsHostCaption ? 2 : 3)
	}
}

private struct UnreadSessionBadge: View {
	var body: some View {
		Circle()
			.fill(.tint)
			.frame(width: 10, height: 10)
			.accessibilityLabel("Unread messages")
	}
}

#Preview {
	let preview = {
		let db = AppDatabase.preview()
		try! db.saveServerURL("http://localhost:3000")

		try! db.dbQueue.write { dbConn in
			let now = Date()
			var macHost = Host(id: nil, location: "nakajima@mac-studio", createdAt: now, updatedAt: now)
			try macHost.insert(dbConn)

			var linuxHost = Host(id: nil, location: "nakajima@devbox", createdAt: now, updatedAt: now)
			try linuxHost.insert(dbConn)

			var liveTranscriptSession = PiSession(
				id: nil,
				hostID: macHost.id!,
				summary: "Watch live transcripts",
				sessionID: "sidebar-preview-session-read",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				cwd: "/Users/nakajima/apps/ThatApp",
				lastMessage: nil,
				lastUserMessageAt: now.addingTimeInterval(-240),
				lastMessageAt: now.addingTimeInterval(-120),
				lastMessageRole: "assistant",
				lastReadMessageAt: now.addingTimeInterval(-120),
				isCliActive: true,
				startedAt: now.addingTimeInterval(-600),
				lastSeenAt: now.addingTimeInterval(-120)
			)
			try liveTranscriptSession.insert(dbConn)

			var groupedUnreadSession = PiSession(
				id: nil,
				hostID: macHost.id!,
				summary: "Ship read badges",
				sessionID: "sidebar-preview-session-unread",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				cwd: "/Users/nakajima/apps/ThatApp",
				lastMessage: nil,
				lastUserMessageAt: now.addingTimeInterval(-30),
				lastMessageAt: now,
				lastMessageRole: "assistant",
				lastReadMessageAt: now.addingTimeInterval(-300),
				isCliActive: true,
				startedAt: now.addingTimeInterval(-1800),
				lastSeenAt: now
			)
			try groupedUnreadSession.insert(dbConn)

			var differentHostSameCwd = PiSession(
				id: nil,
				hostID: linuxHost.id!,
				summary: "Check background jobs",
				sessionID: "sidebar-preview-session-different-host",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				cwd: "/Users/nakajima/apps/ThatApp",
				lastMessage: nil,
				lastUserMessageAt: now.addingTimeInterval(-600),
				lastMessageAt: now.addingTimeInterval(-540),
				lastMessageRole: "assistant",
				lastReadMessageAt: now.addingTimeInterval(-540),
				isCliActive: true,
				startedAt: now.addingTimeInterval(-1200),
				lastSeenAt: now.addingTimeInterval(-540)
			)
			try differentHostSameCwd.insert(dbConn)

			var inactiveSession = PiSession(
				id: nil,
				hostID: macHost.id!,
				summary: "Old debugging session",
				sessionID: "sidebar-preview-session-inactive",
				sessionFile: nil,
				model: "anthropic/claude-sonnet",
				cwd: "/home/nakajima/apps/ThisApp",
				lastMessage: nil,
				lastUserMessageAt: now.addingTimeInterval(-4200),
				lastMessageAt: now.addingTimeInterval(-3600),
				lastMessageRole: "assistant",
				lastReadMessageAt: now.addingTimeInterval(-3600),
				isCliActive: false,
				startedAt: now.addingTimeInterval(-7200),
				lastSeenAt: now.addingTimeInterval(-3600)
			)
			try inactiveSession.insert(dbConn)
		}

		return NavigationStack {
			SidebarView(selectedSessionID: .constant(nil))
		}
		.environment(\.appDatabase, db)
		.environment(\.pimuxServerClient, try! PimuxServerClient(baseURL: "http://localhost:3000"))
		.databaseContext(.readWrite { db.dbQueue })
	}()

	preview
}
