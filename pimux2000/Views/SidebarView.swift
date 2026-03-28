import Foundation
import GRDB
import GRDBQuery
import SwiftUI

struct HostsRequest: ValueObservationQueryable {
	static var defaultValue: [Host] { [] }

	func fetch(_ db: Database) throws -> [Host] {
		try Host.order(Column("updatedAt").desc).fetchAll(db)
	}
}

struct SidebarView: View {
	@Environment(\.databaseContext) private var dbContext
	@Query(PiSessionsRequest()) private var sessions: [SessionInfo]
	@Query(HostsRequest()) private var hosts: [Host]
	@Query(CurrentServerConfigurationRequest()) private var serverConfiguration: ServerConfiguration?
	@Binding var selectedSessionID: String?
	@State private var isShowingServerSheet = false
	@State private var isShowingAddHostSheet = false
	@State private var isShowingSettings = false
	@State private var hostMutationErrorMessage: String?

	var body: some View {
		List(selection: $selectedSessionID) {
			Section("Recent Sessions") {
				if sessions.isEmpty {
					Text("No recent sessions")
						.foregroundStyle(.secondary)
				} else {
					ForEach(sessions, id: \.session.sessionID) { sessionInfo in
						HStack(alignment: .top, spacing: 12) {
							VStack(alignment: .leading, spacing: 4) {
								Text(verbatim: sessionInfo.session.summary)
								HStack(spacing: 6) {
									SessionActivityBadge(isActive: sessionInfo.session.isCliActive)
									VStack(alignment: .leading, spacing: 4) {
										if let lastMessageAt = sessionInfo.session.lastMessageAt {
											Text(verbatim: lastMessageAt.formatted(.dateTime))
										}
										Text(verbatim: sessionInfo.host.displayName)
											.bold()
									}
								}
								.font(.caption)
								.foregroundStyle(.secondary)
							}

							Spacer(minLength: 0)

							if sessionInfo.session.isUnread && selectedSessionID != sessionInfo.session.sessionID {
								UnreadSessionBadge()
							}
						}
						.tag(sessionInfo.session.sessionID)
						.contentShape(Rectangle())
						.onTapGesture {
							selectedSessionID = sessionInfo.session.sessionID
						}
					}
				}
			}

			if serverConfiguration != nil || !hosts.isEmpty {
				Section("Hosts") {
					ForEach(hosts) { host in
						Text(verbatim: host.displayName)
							.bold()
							.swipeActions {
								Button(role: .destructive) {
									Task { await deleteHost(host) }
								} label: {
									Label("Delete", systemImage: "trash")
								}
							}
					}

					Button {
						isShowingAddHostSheet = true
					} label: {
						Label("Add Host", systemImage: "plus")
					}
					.disabled(serverConfiguration == nil)
				}
			}
		}
		.refreshable {
			let syncer = PiSessionSync(dbContext: dbContext)
			await syncer.sync()
		}
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					isShowingServerSheet = true
				} label: {
					Label(serverConfiguration == nil ? "Connect Server" : "Server", systemImage: "server.rack")
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
			ServerConnectionSheet(initialServerURL: serverConfiguration?.serverURL ?? "")
		}
		.sheet(isPresented: $isShowingAddHostSheet) {
			AddHostSheet { location in
				try await addHost(location: location)
			}
		}
		.alert("Host Error", isPresented: Binding(
			get: { hostMutationErrorMessage != nil },
			set: { if !$0 { hostMutationErrorMessage = nil } }
		)) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(verbatim: hostMutationErrorMessage ?? "")
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

	private func addHost(location: String) async throws {
		guard let serverConfiguration else {
			throw PimuxServerError.serverError("No pimux server configured.")
		}

		let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
		try await client.addHost(location: location)
		let syncer = PiSessionSync(dbContext: dbContext)
		await syncer.sync()
	}

	private func deleteHost(_ host: Host) async {
		guard let serverConfiguration else {
			hostMutationErrorMessage = "No pimux server configured."
			return
		}

		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			try await client.deleteHost(location: host.location)
			let syncer = PiSessionSync(dbContext: dbContext)
			await syncer.sync()
		} catch {
			hostMutationErrorMessage = error.localizedDescription
		}
	}
}

private struct SessionActivityBadge: View {
	let isActive: Bool

	var body: some View {
		Circle()
			.fill(isActive ? .green : .gray.opacity(0.4))
			.frame(width: 8, height: 8)
			.accessibilityLabel(isActive ? "Active CLI session" : "Inactive CLI session")
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
	let db = AppDatabase.preview()
	try! db.saveServerConfiguration(serverURL: "http://localhost:3000")

	try! db.dbQueue.write { dbConn in
		let now = Date()
		var host = Host(id: nil, location: "nakajima@mac-studio", createdAt: now, updatedAt: now)
		try host.insert(dbConn)

		var activeSession = PiSession(
			id: nil,
			hostID: host.id!,
			summary: "Watch live transcripts",
			sessionID: "sidebar-preview-session-read",
			sessionFile: nil,
			model: "anthropic/claude-sonnet",
			lastMessage: nil,
			lastMessageAt: now.addingTimeInterval(-120),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-120),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-600),
			lastSeenAt: now.addingTimeInterval(-120)
		)
		try activeSession.insert(dbConn)

		var unreadSession = PiSession(
			id: nil,
			hostID: host.id!,
			summary: "Ship read badges",
			sessionID: "sidebar-preview-session-unread",
			sessionFile: nil,
			model: "anthropic/claude-sonnet",
			lastMessage: nil,
			lastMessageAt: now,
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-300),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-1800),
			lastSeenAt: now
		)
		try unreadSession.insert(dbConn)

		var inactiveSession = PiSession(
			id: nil,
			hostID: host.id!,
			summary: "Old debugging session",
			sessionID: "sidebar-preview-session-inactive",
			sessionFile: nil,
			model: "anthropic/claude-sonnet",
			lastMessage: nil,
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
	.databaseContext(.readWrite { db.dbQueue })
}
