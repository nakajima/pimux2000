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
	@Query(PiSessionsRequest()) private var sessions: [PiSession]
	@Query(HostsRequest()) private var hosts: [Host]
	@State private var isAddingServer = false
	@State private var isShowingSettings = false

	var body: some View {
		List {
			ForEach(sessions) { session in
				NavigationLink(session.summary, value: Route.piSession(session))
			}

			Section {
				ForEach(hosts) { host in
					Text(host.displayName)
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
			ToolbarItem(placement: .bottomBar) {
				Button { isShowingSettings = true } label: {
					Label("Settings", systemImage: "gearshape")
				}
			}
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
