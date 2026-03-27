import GRDB
import GRDBQuery
import Pi
import SwiftUI

struct SessionInfo: Decodable, FetchableRecord, Identifiable, Equatable, Hashable {
	var piSession: PiSession
	var host: Host
	var id: Int64? { piSession.id }
}

struct PiSessionsRequest: ValueObservationQueryable {
	static var defaultValue: [SessionInfo] { [] }

	func fetch(_ db: Database) throws -> [SessionInfo] {
		try PiSession
			.including(required: PiSession.host)
			.order(Column("lastMessageAt").desc)
			.asRequest(of: SessionInfo.self)
			.fetchAll(db)
	}
}



struct DetailView: View {
	var body: some View {
		List {
			Text("WIP")
		}
	}
}

struct ContentView: View {
	@Environment(\.databaseContext) var dbContext
	
	var body: some View {
		NavigationSplitView(
			sidebar: {
				SidebarView()
					.navigationDestination(for: Route.self) { route in
						switch route {
						case .piSession(let session):
							PiSessionView(session: session)
						}
					}
			},
			detail: {
				ContentUnavailableView("No session selected", systemImage: "questionmark.message")
					.navigationDestination(for: Route.self) { route in
						switch route {
						case .piSession(let session):
							PiSessionView(session: session)
						}
					}
			}
		)
			.task {
				while !Task.isCancelled {
					let syncer = PiSessionSync(dbContext: dbContext)
					await syncer.sync()
					try? await Task.sleep(for: .seconds(3))
				}
			}
	}
}

#Preview {
	let db = AppDatabase.preview()
	try! db.addHost(sshTarget: "nakajima@arch")
	return ContentView()
		.environment(\.appDatabase, db)
		.databaseContext(.readWrite { db.dbQueue })
}
