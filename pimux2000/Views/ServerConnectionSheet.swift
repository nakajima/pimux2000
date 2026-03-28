import SwiftUI

struct ServerConnectionSheet: View {
	@Environment(\.appDatabase) private var appDatabase
	@Environment(\.dismiss) private var dismiss
	@State private var serverURL: String
	@State private var isConnecting = false
	@State private var errorMessage: String?

	init(initialServerURL: String = "") {
		self._serverURL = State(initialValue: initialServerURL)
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
						Text(errorMessage)
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

#Preview {
	ServerConnectionSheet(initialServerURL: "http://localhost:3000")
		.environment(\.appDatabase, AppDatabase.preview())
}
