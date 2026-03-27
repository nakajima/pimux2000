import GRDB
import GRDBQuery
import Pi
import SwiftUI
import Foundation

struct HostsRequest: ValueObservationQueryable {
	static var defaultValue: [Host] { [] }

	func fetch(_ db: Database) throws -> [Host] {
		try Host.order(Column("updatedAt").desc).fetchAll(db)
	}
}

struct SidebarView: View {
	@Environment(\.appDatabase) private var appDatabase
	@Environment(\.databaseContext) private var dbContext
	@Query(PiSessionsRequest()) private var sessions: [SessionInfo]
	@Query(HostsRequest()) private var hosts: [Host]
	@Binding var selectedSessionID: String?
	@State private var isAddingServer = false
	@State private var isShowingSettings = false

	var body: some View {
		List(selection: $selectedSessionID) {
			ForEach(sessions, id: \.session.sessionID) { sessionInfo in
				VStack(alignment: .leading) {
					Text(sessionInfo.session.summary)
					VStack(alignment: .leading) {
						if let lastMessageAt = sessionInfo.session.lastMessageAt {
							Text(lastMessageAt.formatted(.dateTime))
						}
						Text(sessionInfo.host.displayName)
							.bold()
					}
					.font(.caption)
					.foregroundStyle(.secondary)
				}
				.tag(sessionInfo.session.sessionID)
				.contentShape(Rectangle())
				.onTapGesture {
					selectedSessionID = sessionInfo.session.sessionID
				}
			}

			Section {
				ForEach(hosts) { host in
					Text(host.displayName)
						.bold()
				}
				.onDelete { indexSet in
					let idsToDelete = indexSet.compactMap { hosts[$0].id }
					try? appDatabase?.deleteHosts(ids: idsToDelete)
				}
			} header: {
				Text("Servers")
			}
		}
		.refreshable {
			let syncer = PiSessionSync(dbContext: dbContext)
			await syncer.sync()
		}
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button { isAddingServer = true } label: {
					Label("Add Server", systemImage: "plus")
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
		.sheet(isPresented: $isAddingServer) {
			AddServerSheet()
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
}

#Preview {
	let db = AppDatabase.preview()

	try! db.dbQueue.write { dbConn in
		var host = Host(sshTarget: "nakajima@mac-studio", createdAt: Date(), updatedAt: Date())
		try host.insert(dbConn)

		var session = PiSession(
			hostID: host.id!,
			summary: "Debug remote sync",
			sessionID: "sidebar-preview-session",
			sessionFile: "/tmp/sidebar-preview.jsonl",
			model: "anthropic/claude-sonnet",
			lastMessage: "Looks good",
			lastMessageAt: Date(),
			lastMessageRole: "assistant",
			startedAt: Date(),
			lastSeenAt: Date()
		)
		try session.insert(dbConn)
	}

	return NavigationStack {
		SidebarView(selectedSessionID: .constant(nil))
	}
	.environment(\.appDatabase, db)
	.databaseContext(.readWrite { db.dbQueue })
}
