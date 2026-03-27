import GRDB
import GRDBQuery
import Pi
import SwiftUI

struct SessionInfo: Decodable, FetchableRecord, Identifiable, Equatable, Hashable {
	var session: PiSession
	var host: Host
	var id: Int64? { session.id }
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
	@Query(PiSessionsRequest()) private var sessions: [SessionInfo]
	@State private var selectedSessionID: String?
	
	var body: some View {
		NavigationSplitView(
			sidebar: {
				SidebarView(selectedSessionID: $selectedSessionID)
			},
			detail: {
				NavigationStack {
					Group {
						if let selectedSession {
							PiSessionView(session: selectedSession)
								.id(selectedSession.sessionID)
						} else {
							ContentUnavailableView("No session selected", systemImage: "questionmark.message")
						}
					}
					.navigationDestination(for: Route.self, destination: destination)
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

	private var selectedSession: PiSession? {
		sessions.first { $0.session.sessionID == selectedSessionID }?.session
	}

	@ViewBuilder
	private func destination(for route: Route) -> some View {
		switch route {
		case .piSession(let session):
			PiSessionView(session: session)
				.id(session.sessionID)
		case .messageContext(let context):
			MessageContextView(route: context)
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
