import GRDB
import GRDBQuery
import Pi
import SwiftUI

struct HostsRequest: ValueObservationQueryable {
	static var defaultValue: [Host] { [] }

	func fetch(_ db: Database) throws -> [Host] {
		try Host.order(Column("updatedAt").desc).fetchAll(db)
	}
}

struct SidebarView: View {
	@Environment(\.appDatabase) private var appDatabase
	@Query(PiSessionsRequest()) private var sessions: [SessionInfo]
	@Query(HostsRequest()) private var hosts: [Host]
	@State private var isAddingServer = false
	@State private var isShowingSettings = false

	var body: some View {
		List {
			ForEach(sessions) { sessionInfo in
				NavigationLink(value: Route.piSession(sessionInfo.piSession)) {
					VStack(alignment: .leading) {
						Text(sessionInfo.piSession.summary)
						if let lastMessage = sessionInfo.piSession.lastMessage, lastMessage != sessionInfo.piSession.summary {
							Text(lastMessage)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(2)
						}
						Text(sessionInfo.host.displayName)
							.font(.caption2)
							.foregroundStyle(.tertiary)
					}
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
