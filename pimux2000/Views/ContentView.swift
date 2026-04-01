import GRDB
import GRDBQuery
import SwiftUI

struct SessionInfo: Decodable, FetchableRecord, Identifiable, Equatable, Hashable {
	var session: PiSession
	var host: Host
	var id: Int64? { session.id }
	
	var description: String {
		if let cwd = session.cwd {
			let host = host.location.split(separator: "@").last ?? ""
			let cwd = cwd.replacing(/\/Users\/\w+\/|\/home\/\w+\//, with: "~/")
			return "\(host):\(cwd)"
		} else {
			return host.displayName
		}
	}
}

struct PiSessionsRequest: ValueObservationQueryable {
	static var defaultValue: [SessionInfo] { [] }

	func fetch(_ db: Database) throws -> [SessionInfo] {
		try PiSession
			.including(required: PiSession.host)
			.order(
				Column("isCliActive").desc,
				Column("lastUserMessageAt").desc,
				Column("startedAt").desc,
				Column("sessionID").asc
			)
			.asRequest(of: SessionInfo.self)
			.fetchAll(db)
	}
}

struct ContentView: View {
	@Environment(\.databaseContext) private var dbContext
	@Query(PiSessionsRequest()) private var sessions: [SessionInfo]
	@Query(CurrentServerConfigurationRequest()) private var serverConfiguration: ServerConfiguration?
	@State private var selectedSessionID: String?
	@State private var columnVisibility: NavigationSplitViewVisibility = .automatic

	var body: some View {
		NavigationSplitView(columnVisibility: $columnVisibility) {
			SidebarView(selectedSessionID: $selectedSessionID)
		} detail: {
			detailView
		}
		.task(id: serverConfiguration?.serverURL ?? "") {
			guard serverConfiguration != nil else { return }
			let syncer = PiSessionSync(dbContext: dbContext)
			await syncer.sync()
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(3))
				await syncer.sync()
			}
		}
		.onChange(of: selectedSessionID) {
			guard let selectedSessionID else { return }
			SessionSelectionPerformanceTrace.beginSelection(
				sessionID: selectedSessionID,
				source: "ContentView.selectedSessionID"
			)
		}
		.onChange(of: sessions.map(\.session.sessionID)) {
			guard !sessions.isEmpty else {
				selectedSessionID = nil
				return
			}

			if let selectedSessionID,
				sessions.contains(where: { $0.session.sessionID == selectedSessionID }) {
				return
			}

			self.selectedSessionID = sessions.first?.session.sessionID
		}
	}

	@ViewBuilder
	private var detailView: some View {
		NavigationStack {
			Group {
				if serverConfiguration == nil {
					ContentUnavailableView(
						"No Server Configured",
						systemImage: "network.slash",
						description: Text("Connect this app to a pimux server from the sidebar.")
					)
				} else if let selectedSession {
					PiSessionView(session: selectedSession, columnVisibility: $columnVisibility)
						.id(selectedSession.sessionID)
				} else if sessions.isEmpty {
					ContentUnavailableView(
						"No Recent Sessions",
						systemImage: "bubble.left.and.bubble.right"
					)
				} else {
					ContentUnavailableView(
						"No Session Selected",
						systemImage: "questionmark.message"
					)
				}
			}
			.navigationDestination(for: Route.self, destination: destination)
		}
	}

	private var selectedSession: PiSession? {
		sessions.first { $0.session.sessionID == selectedSessionID }?.session
	}

	@ViewBuilder
	private func destination(for route: Route) -> some View {
		switch route {
		case .piSession(let session):
			PiSessionView(session: session, columnVisibility: $columnVisibility)
				.id(session.sessionID)
		case .messageContext(let context):
			MessageContextView(route: context)
		}
	}
}

#Preview {
	let preview = {
		let db = AppDatabase.preview()
		try! db.saveServerConfiguration(serverURL: "http://localhost:3000")
		try! db.dbQueue.write { dbConn in
			var host = Host(id: nil, location: "nakajima@arch", createdAt: Date(), updatedAt: Date())
			try host.insert(dbConn)
		}
		return ContentView()
			.environment(\.appDatabase, db)
			.databaseContext(.readWrite { db.dbQueue })
	}()

	preview
}
