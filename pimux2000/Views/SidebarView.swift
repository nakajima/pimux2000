//
//  SidebarView.swift
//  pimux2000
//
//  Created by Pat Nakajima on 3/26/26.
//

import SwiftUI
import GRDBQuery
import GRDB
import Pi

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
	@State private var isAddingHost = false
	@State private var isConnecting = false
	@State private var newHostTarget = ""
	@State private var addHostError: String?

	var body: some View {
		List {
			ForEach(sessions) { session in
				NavigationLink(session.summary, value: Route.piSession(session))
			}

			Section {
				ForEach(hosts) { host in
					Text(host.sshTarget)
				}
			} header: {
				Text("Hosts")
			}
		}
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button { isAddingHost = true } label: {
					Label("Add Host", systemImage: "plus")
				}
				.disabled(isConnecting)
			}
		}
		.alert("Add Host", isPresented: $isAddingHost) {
			TextField("user@host", text: $newHostTarget)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			Button("Add") { Task { await addHost() } }
			Button("Cancel", role: .cancel) { newHostTarget = "" }
		}
		.alert("Connection Failed", isPresented: .init(
			get: { addHostError != nil },
			set: { if !$0 { addHostError = nil } }
		)) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(addHostError ?? "")
		}
		.overlay {
			if isConnecting {
				ProgressView("Connecting…")
					.padding()
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
			}
		}
	}

	private func addHost() async {
		let trimmed = newHostTarget.trimmingCharacters(in: .whitespacesAndNewlines)
		newHostTarget = ""
		guard !trimmed.isEmpty else { return }

		isConnecting = true
		defer { isConnecting = false }

		let client = PiClient(configuration: .init(sshTarget: trimmed))

		do {
			_ = try await client.listSessions()
			try appDatabase?.addHost(sshTarget: trimmed)
		} catch {
			addHostError = error.localizedDescription
		}
	}
}
