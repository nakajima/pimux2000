import Combine
import Foundation
import SwiftUI

struct ServerConnectionSheet: View {
	@Environment(\.appDatabase) private var appDatabase
	@Environment(\.dismiss) private var dismiss
	@StateObject private var discovery: PimuxBonjourDiscovery
	@State private var serverURL: String
	@State private var isConnecting = false
	@State private var errorMessage: String?

	@MainActor
	init(
		initialServerURL: String = "",
		discovery: PimuxBonjourDiscovery? = nil
	) {
		self._serverURL = State(initialValue: initialServerURL)
		self._discovery = StateObject(wrappedValue: discovery ?? PimuxBonjourDiscovery())
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("http://localhost:3000", text: $serverURL)
					#if os(iOS)
						.textInputAutocapitalization(.never)
					#endif
						.autocorrectionDisabled()
						.textContentType(.URL)
				} footer: {
					Text("Enter the base URL of your pimux server. If you omit the scheme, http:// is assumed.")
				}

				Section {
					if discovery.servers.isEmpty {
						if let discoveryErrorMessage = discovery.errorMessage {
							Text(verbatim: discoveryErrorMessage)
								.foregroundStyle(.secondary)
						} else {
							HStack(spacing: 12) {
								if discovery.isSearching {
									ProgressView()
								}
								Text(discovery.isSearching ? "Searching your local network…" : "No nearby pimux servers found.")
									.foregroundStyle(.secondary)
							}
						}
					} else {
						ForEach(discovery.servers) { server in
							Button {
								serverURL = server.baseURLString
								errorMessage = nil
							} label: {
								HStack(alignment: .top, spacing: 12) {
									VStack(alignment: .leading, spacing: 4) {
										Text(verbatim: server.name)
										Text(verbatim: server.baseURLString)
											.font(.caption)
											.foregroundStyle(.secondary)
										if let version = server.version {
											Text(verbatim: "v\(version)")
												.font(.caption2)
												.foregroundStyle(.secondary)
										}
									}

									Spacer(minLength: 0)

									if selectedNearbyServerID == server.id {
										Image(systemName: "checkmark.circle.fill")
											.foregroundStyle(.tint)
									}
								}
							}
							.buttonStyle(.plain)
						}
					}
				} header: {
					Text("Nearby Servers")
				} footer: {
					Text("Nearby servers are discovered with Bonjour on your local network.")
				}

				Section {
					Button {
						Task { await connect() }
					} label: {
						if isConnecting {
							HStack {
								ProgressView()
								Text("Connecting…")
							}
						} else {
							Text("Connect")
						}
					}
					.disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
				}

				if let errorMessage {
					Section {
						Text(verbatim: errorMessage)
							.foregroundStyle(.red)
					}
				}
			}
			.navigationTitle("Connect Server")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.disabled(isConnecting)
				}
			}
		}
		.onAppear {
			discovery.start()
		}
		.onDisappear {
			discovery.stop()
		}
	}

	private var selectedNearbyServerID: String? {
		discovery.servers.first { $0.baseURLString == serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }?.id
	}

	private func connect() async {
		guard let appDatabase else { return }
		isConnecting = true
		errorMessage = nil
		defer { isConnecting = false }

		do {
			let normalized = try PimuxServerClient.normalizedBaseURLString(from: serverURL)
			let client = try PimuxServerClient(baseURL: normalized)
			try await client.health()
			try appDatabase.saveServerConfiguration(serverURL: normalized)
			dismiss()
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

struct DiscoveredPimuxServer: Identifiable, Equatable {
	let name: String
	let baseURLString: String
	let version: String?

	var id: String {
		"\(name)|\(baseURLString)"
	}

	init(name: String, baseURLString: String, version: String? = nil) {
		self.name = name
		self.baseURLString = baseURLString
		self.version = version
	}

	init?(service: NetService) {
		guard service.port > 0 else { return nil }
		guard let host = Self.hostName(from: service) else { return nil }

		let txtValues = Self.txtValues(from: service.txtRecordData())
		let scheme = Self.scheme(from: txtValues)
		let path = Self.path(from: txtValues)

		var components = URLComponents()
		components.scheme = scheme
		components.host = host
		components.port = service.port
		if path != "/" {
			components.path = path
		}

		guard let baseURLString = components.string else { return nil }

		self.init(
			name: service.name,
			baseURLString: baseURLString,
			version: txtValues["version"]
		)
	}

	private static func hostName(from service: NetService) -> String? {
		let trimmed = service.hostName?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: CharacterSet(charactersIn: "."))
		guard let trimmed, !trimmed.isEmpty else { return nil }
		return trimmed
	}

	private static func txtValues(from data: Data?) -> [String: String] {
		guard let data else { return [:] }
		return NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { partialResult, pair in
			guard let value = String(data: pair.value, encoding: .utf8) else { return }
			partialResult[pair.key.lowercased()] = value
		}
	}

	private static func scheme(from txtValues: [String: String]) -> String {
		let candidate = txtValues["scheme"] ?? txtValues["proto"] ?? "http"
		let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return ["http", "https"].contains(normalized) ? normalized : "http"
	}

	private static func path(from txtValues: [String: String]) -> String {
		let candidate = txtValues["path"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/"
		guard !candidate.isEmpty else { return "/" }
		return candidate.hasPrefix("/") ? candidate : "/\(candidate)"
	}
}

final class PimuxBonjourDiscovery: NSObject, ObservableObject {
	@Published private(set) var servers: [DiscoveredPimuxServer]
	@Published private(set) var isSearching = false
	@Published private(set) var errorMessage: String?

	private let isPreview: Bool
	private var browser: NetServiceBrowser?
	private var resolvingServices: [String: NetService] = [:]
	private var discoveredServersByID: [String: DiscoveredPimuxServer] = [:]

	init(servers: [DiscoveredPimuxServer] = [], isPreview: Bool = false) {
		self.servers = servers.sorted(by: Self.shouldSortBefore)
		self.isPreview = isPreview
		super.init()
	}

	func start() {
		guard !isPreview, browser == nil else { return }

		errorMessage = nil
		isSearching = true

		let browser = NetServiceBrowser()
		browser.delegate = self
		browser.searchForServices(ofType: "_pimux._tcp.", inDomain: "local.")
		self.browser = browser
	}

	func stop() {
		browser?.stop()
		browser = nil
		isSearching = false

		for service in resolvingServices.values {
			service.stop()
		}
		resolvingServices.removeAll()
	}

	static func preview(_ servers: [DiscoveredPimuxServer]) -> PimuxBonjourDiscovery {
		PimuxBonjourDiscovery(servers: servers, isPreview: true)
	}

	private func updateServers() {
		servers = discoveredServersByID.values.sorted(by: Self.shouldSortBefore)
	}

	private nonisolated static func shouldSortBefore(_ lhs: DiscoveredPimuxServer, _ rhs: DiscoveredPimuxServer) -> Bool {
		if lhs.name != rhs.name {
			return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
		}
		return lhs.baseURLString.localizedCaseInsensitiveCompare(rhs.baseURLString) == .orderedAscending
	}

	private nonisolated static func serviceID(for service: NetService) -> String {
		"\(service.name)|\(service.type)|\(service.domain)"
	}

	private nonisolated static func describeError(_ errorDict: [String: NSNumber], prefix: String) -> String {
		let code = errorDict[NetService.errorCode]?.intValue ?? 0
		if code == 0 {
			return "\(prefix). If local network access is disabled, re-enable it in Settings and try again."
		}
		return "\(prefix) (NetService error \(code)). If local network access is disabled, re-enable it in Settings and try again."
	}
}

extension PimuxBonjourDiscovery: NetServiceBrowserDelegate {
	func netServiceBrowserWillSearch(_: NetServiceBrowser) {
		isSearching = true
	}

	func netServiceBrowserDidStopSearch(_: NetServiceBrowser) {
		isSearching = false
	}

	func netServiceBrowser(_: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
		isSearching = false
		errorMessage = Self.describeError(errorDict, prefix: "Local network discovery failed")
	}

	func netServiceBrowser(_: NetServiceBrowser, didFind service: NetService, moreComing _: Bool) {
		let serviceID = Self.serviceID(for: service)
		resolvingServices[serviceID]?.stop()
		service.delegate = self
		resolvingServices[serviceID] = service
		service.resolve(withTimeout: 5)
	}

	func netServiceBrowser(_: NetServiceBrowser, didRemove service: NetService, moreComing _: Bool) {
		let serviceID = Self.serviceID(for: service)
		resolvingServices[serviceID]?.stop()
		resolvingServices.removeValue(forKey: serviceID)
		discoveredServersByID.removeValue(forKey: serviceID)
		updateServers()
	}
}

extension PimuxBonjourDiscovery: NetServiceDelegate {
	func netServiceDidResolveAddress(_ sender: NetService) {
		let serviceID = Self.serviceID(for: sender)
		resolvingServices.removeValue(forKey: serviceID)
		guard let server = DiscoveredPimuxServer(service: sender) else { return }
		errorMessage = nil
		discoveredServersByID[serviceID] = server
		updateServers()
	}

	func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
		let serviceID = Self.serviceID(for: sender)
		resolvingServices.removeValue(forKey: serviceID)
		guard discoveredServersByID.isEmpty else { return }
		errorMessage = Self.describeError(errorDict, prefix: "Couldn’t resolve a nearby pimux server")
	}
}

#Preview {
	ServerConnectionSheet(
		initialServerURL: "",
		discovery: .preview([
			DiscoveredPimuxServer(
				name: "pimux on mac-studio:3000",
				baseURLString: "http://mac-studio.local:3000",
				version: "0.2.1"
			),
			DiscoveredPimuxServer(
				name: "pimux on macbook-air:3000",
				baseURLString: "http://macbook-air.local:3000",
				version: "0.2.1"
			),
		])
	)
	.environment(\.appDatabase, AppDatabase.preview())
}
