import SwiftUI

struct AddHostSheet: View {
	@Environment(\.dismiss) private var dismiss
	@State private var location: String
	@State private var isSaving = false
	@State private var errorMessage: String?
	var onAdd: (String) async throws -> Void

	init(initialLocation: String = "", onAdd: @escaping (String) async throws -> Void) {
		self._location = State(initialValue: initialLocation)
		self.onAdd = onAdd
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("nakajima@macstudio", text: $location)
						#if os(iOS)
						.textInputAutocapitalization(.never)
						#endif
						.autocorrectionDisabled()
				} footer: {
					Text("Add a host location to the server’s expected-host registry.")
				}

				Section {
					Button {
						Task { await addHost() }
					} label: {
						if isSaving {
							HStack {
								ProgressView()
								Text("Saving…")
							}
						} else {
							Text("Add Host")
						}
					}
					.disabled(location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
				}

				if let errorMessage {
					Section {
						Text(verbatim: errorMessage)
							.foregroundStyle(.red)
					}
				}
			}
			.navigationTitle("Add Host")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.disabled(isSaving)
				}
			}
		}
	}

	private func addHost() async {
		let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedLocation.isEmpty else {
			errorMessage = "Enter a host location."
			return
		}

		isSaving = true
		errorMessage = nil
		defer { isSaving = false }

		do {
			try await onAdd(trimmedLocation)
			dismiss()
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

#Preview {
	AddHostSheet(initialLocation: "nakajima@macstudio") { _ in }
}
