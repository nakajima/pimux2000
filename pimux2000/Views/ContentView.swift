import Foundation
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
	@Query(HostsRequest()) private var hosts: [Host]
	@State private var selectedSessionID: String?
	@State private var launchUpdatePrompt: LaunchServerUpdatePrompt?
	@State private var pendingLaunchUpdatePrompts: [LaunchServerUpdatePrompt] = []
	@State private var launchWarning: LaunchServerWarning?
	@State private var pendingLaunchWarnings: [LaunchServerWarning] = []
	@State private var updateSheetRequest: ServerUpdateRequest?
	@State private var didRunLaunchServerCheck = false
	
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
		.safeAreaInset(edge: .top) {
			if let launchWarning {
				LaunchServerWarningBanner(
					warning: launchWarning,
					onUpdate: {
						updateSheetRequest = ServerUpdateRequest(sshTarget: launchWarning.host.sshTarget)
						advanceLaunchWarningQueue()
					},
					onDismiss: {
						advanceLaunchWarningQueue()
					}
				)
				.padding(.horizontal)
				.padding(.top, 8)
			}
		}
		.task {
			while !Task.isCancelled {
				let syncer = PiSessionSync(dbContext: dbContext)
				await syncer.sync()
				try? await Task.sleep(for: .seconds(3))
			}
		}
		.task(id: hosts.map(\.sshTarget).joined(separator: "|")) {
			guard !didRunLaunchServerCheck, !hosts.isEmpty else { return }
			didRunLaunchServerCheck = true
			await checkSavedHostServerVersions()
		}
		.alert(
			"Server Update Available",
			isPresented: Binding(
				get: { launchUpdatePrompt != nil },
				set: { isPresented in
					if !isPresented {
						advanceLaunchUpdatePromptQueue()
					}
				}
			),
			presenting: launchUpdatePrompt
		) { prompt in
			Button("Not Now", role: .cancel) {}
			Button("Update") {
				updateSheetRequest = ServerUpdateRequest(sshTarget: prompt.host.sshTarget)
			}
		} message: { prompt in
			Text(prompt.message)
		}
		.sheet(item: $updateSheetRequest) { request in
			AddServerSheet(initialSSHTarget: request.sshTarget, mode: .update)
		}
	}

	private var selectedSession: PiSession? {
		sessions.first { $0.session.sessionID == selectedSessionID }?.session
	}

	private func checkSavedHostServerVersions() async {
		var prompts: [LaunchServerUpdatePrompt] = []
		var warnings: [LaunchServerWarning] = []

		await withTaskGroup(of: HostServerVersionStatus.self) { group in
			for host in hosts {
				group.addTask {
					await Self.checkServerVersion(for: host)
				}
			}

			for await status in group {
				switch status {
				case .current:
					break
				case .outdated(let prompt):
					prompts.append(prompt)
				case .warning(let warning):
					warnings.append(warning)
				}
			}
		}

		prompts.sort { $0.host.displayName < $1.host.displayName }
		warnings.sort { $0.host.displayName < $1.host.displayName }

		launchUpdatePrompt = prompts.first
		pendingLaunchUpdatePrompts = Array(prompts.dropFirst())
		launchWarning = warnings.first
		pendingLaunchWarnings = Array(warnings.dropFirst())
	}

	private func advanceLaunchUpdatePromptQueue() {
		if let next = pendingLaunchUpdatePrompts.first {
			launchUpdatePrompt = next
			pendingLaunchUpdatePrompts.removeFirst()
		} else {
			launchUpdatePrompt = nil
		}
	}

	private func advanceLaunchWarningQueue() {
		if let next = pendingLaunchWarnings.first {
			launchWarning = next
			pendingLaunchWarnings.removeFirst()
		} else {
			launchWarning = nil
		}
	}

	private static func checkServerVersion(for host: Host) async -> HostServerVersionStatus {
		guard let url = host.healthURL else {
			return .warning(
				LaunchServerWarning(
					host: host,
					message: "Couldn’t verify \(host.displayName). Update it manually if needed."
				)
			)
		}

		do {
			let (data, response) = try await URLSession.shared.data(from: url)
			guard let httpResponse = response as? HTTPURLResponse,
				(200..<300).contains(httpResponse.statusCode) else {
				return .warning(
					LaunchServerWarning(
						host: host,
						message: "Couldn’t verify \(host.displayName). Update it manually if needed."
					)
				)
			}

			if let health = try? JSONDecoder().decode(ServerHealthResponse.self, from: data),
				health.ok == true,
				let version = health.version {
				if version == ServerFiles.version {
					return .current
				}
				return .outdated(
					LaunchServerUpdatePrompt(host: host, remoteVersion: version)
				)
			}

			let legacyResponse = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
			if legacyResponse == "ok" {
				return .outdated(
					LaunchServerUpdatePrompt(host: host, remoteVersion: nil)
				)
			}

			return .warning(
				LaunchServerWarning(
					host: host,
					message: "Couldn’t verify \(host.displayName). Update it manually if needed."
				)
			)
		} catch {
			return .warning(
				LaunchServerWarning(
					host: host,
					message: "Couldn’t verify \(host.displayName). The server may be down or need a manual update."
				)
			)
		}
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

private enum HostServerVersionStatus {
	case current
	case outdated(LaunchServerUpdatePrompt)
	case warning(LaunchServerWarning)
}

private struct ServerHealthResponse: Decodable {
	let ok: Bool
	let version: String?
}

private struct LaunchServerUpdatePrompt: Identifiable, Equatable {
	let host: Host
	let remoteVersion: String?

	var id: String { host.sshTarget }

	var message: String {
		if let remoteVersion {
			return "\(host.displayName) is running bundled server version \(remoteVersion), but this app includes \(ServerFiles.version). Update it now?"
		}
		return "\(host.displayName) is running a legacy bundled server without version info. Update it now?"
	}
}

private struct LaunchServerWarning: Identifiable, Equatable {
	let host: Host
	let message: String

	var id: String { host.sshTarget }
}

private struct ServerUpdateRequest: Identifiable, Equatable {
	let sshTarget: String

	var id: String { sshTarget }
}

private struct LaunchServerWarningBanner: View {
	let warning: LaunchServerWarning
	let onUpdate: () -> Void
	let onDismiss: () -> Void

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.yellow)

			VStack(alignment: .leading, spacing: 8) {
				Text("Server needs attention")
					.font(.headline)
				Text(warning.message)
					.font(.caption)
					.foregroundStyle(.secondary)

				HStack {
					Button("Update", action: onUpdate)
						.buttonStyle(.borderedProminent)
					Button("Dismiss", role: .cancel, action: onDismiss)
						.buttonStyle(.bordered)
				}
			}

			Spacer(minLength: 0)
		}
		.padding(12)
		.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
	}
}

#Preview {
	let db = AppDatabase.preview()
	try! db.addHost(sshTarget: "nakajima@arch")
	return ContentView()
		.environment(\.appDatabase, db)
		.databaseContext(.readWrite { db.dbQueue })
}
