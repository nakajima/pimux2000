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
	@State private var launchVersionPrompt: LaunchVersionPrompt?
	@State private var pendingLaunchVersionPrompts: [LaunchVersionPrompt] = []
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
			launchVersionPrompt?.title ?? "Version Mismatch",
			isPresented: Binding(
				get: { launchVersionPrompt != nil },
				set: { isPresented in
					if !isPresented {
						advanceLaunchVersionPromptQueue()
					}
				}
			),
			presenting: launchVersionPrompt
		) { prompt in
			switch prompt {
			case .updateServer(let host, _):
				Button("Not Now", role: .cancel) {}
				Button("Update") {
					updateSheetRequest = ServerUpdateRequest(sshTarget: host.sshTarget)
				}
			case .updateApp:
				Button("OK", role: .cancel) {}
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
		var prompts: [LaunchVersionPrompt] = []
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
				case .prompt(let prompt):
					prompts.append(prompt)
				case .warning(let warning):
					warnings.append(warning)
				}
			}
		}

		prompts.sort { $0.host.displayName < $1.host.displayName }
		warnings.sort { $0.host.displayName < $1.host.displayName }

		launchVersionPrompt = prompts.first
		pendingLaunchVersionPrompts = Array(prompts.dropFirst())
		launchWarning = warnings.first
		pendingLaunchWarnings = Array(warnings.dropFirst())
	}

	private func advanceLaunchVersionPromptQueue() {
		if let next = pendingLaunchVersionPrompts.first {
			launchVersionPrompt = next
			pendingLaunchVersionPrompts.removeFirst()
		} else {
			launchVersionPrompt = nil
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

	private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
		let lhsParts = lhs.split(separator: ".", omittingEmptySubsequences: false)
		let rhsParts = rhs.split(separator: ".", omittingEmptySubsequences: false)
		guard !lhsParts.isEmpty, !rhsParts.isEmpty else { return nil }

		let lhsNumbers = lhsParts.compactMap { Int($0) }
		let rhsNumbers = rhsParts.compactMap { Int($0) }
		guard lhsNumbers.count == lhsParts.count, rhsNumbers.count == rhsParts.count else {
			return nil
		}

		for index in 0..<max(lhsNumbers.count, rhsNumbers.count) {
			let lhsValue = index < lhsNumbers.count ? lhsNumbers[index] : 0
			let rhsValue = index < rhsNumbers.count ? rhsNumbers[index] : 0
			if lhsValue < rhsValue {
				return .orderedAscending
			}
			if lhsValue > rhsValue {
				return .orderedDescending
			}
		}

		return .orderedSame
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
			var request = URLRequest(url: url)
			request.cachePolicy = .reloadIgnoringLocalCacheData
			request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
			request.setValue("no-cache", forHTTPHeaderField: "Pragma")

			let (data, response) = try await URLSession.shared.data(for: request)
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
				switch Self.compareVersions(version, ServerFiles.version) {
				case .orderedSame:
					return .current
				case .orderedAscending:
					return .prompt(
						.updateServer(host: host, remoteVersion: version)
					)
				case .orderedDescending:
					return .prompt(
						.updateApp(host: host, remoteVersion: version)
					)
				case nil:
					return .warning(
						LaunchServerWarning(
							host: host,
							message: "Couldn’t compare versions for \(host.displayName). Update the app or server manually if needed."
						)
					)
				}
			}

			let legacyResponse = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
			if legacyResponse == "ok" {
				return .prompt(
					.updateServer(host: host, remoteVersion: nil)
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
	case prompt(LaunchVersionPrompt)
	case warning(LaunchServerWarning)
}

private struct ServerHealthResponse: Decodable {
	let ok: Bool
	let version: String?
}

private enum LaunchVersionPrompt: Identifiable, Equatable {
	case updateServer(host: Host, remoteVersion: String?)
	case updateApp(host: Host, remoteVersion: String)

	var host: Host {
		switch self {
		case .updateServer(let host, _), .updateApp(let host, _):
			host
		}
	}

	var id: String {
		switch self {
		case .updateServer(let host, _):
			return "server-\(host.sshTarget)"
		case .updateApp(let host, _):
			return "app-\(host.sshTarget)"
		}
	}

	var title: String {
		switch self {
		case .updateServer:
			return "Server Update Available"
		case .updateApp:
			return "Update This App"
		}
	}

	var message: String {
		switch self {
		case .updateServer(let host, let remoteVersion):
			if let remoteVersion {
				return "\(host.displayName) is running bundled server version \(remoteVersion), but this app includes \(ServerFiles.version). Update the server now?"
			}
			return "\(host.displayName) is running a legacy bundled server without version info. Update the server now?"
		case .updateApp(let host, let remoteVersion):
			return "\(host.displayName) is running bundled server version \(remoteVersion), which is newer than this app’s bundled version \(ServerFiles.version). Update this iOS app instead of installing an older server."
		}
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
