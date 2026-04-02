import SwiftUI

struct SessionForkMessagePickerView: View {
	let messages: [PimuxSessionForkMessage]
	var isSubmitting: Bool = false
	var errorMessage: String? = nil
	let onSelect: (PimuxSessionForkMessage) -> Void
	let onCancel: () -> Void

	var body: some View {
		NavigationStack {
			List(messages) { message in
				Button {
					onSelect(message)
				} label: {
					VStack(alignment: .leading, spacing: 6) {
						Text(verbatim: message.text)
							.foregroundStyle(.primary)
							.lineLimit(3)
						Text(verbatim: message.entryID)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.padding(.vertical, 4)
				}
				.buttonStyle(.plain)
				.disabled(isSubmitting)
			}
			.navigationTitle("Fork from Message")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel", action: onCancel)
						.disabled(isSubmitting)
				}
			}
			.safeAreaInset(edge: .bottom) {
				if let errorMessage, !errorMessage.isEmpty {
					Text(verbatim: errorMessage)
						.font(.caption)
						.foregroundStyle(.red)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal)
						.padding(.vertical, 10)
						.background(.thinMaterial)
				} else if isSubmitting {
					HStack(spacing: 8) {
						ProgressView()
						Text("Creating fork…")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal)
					.padding(.vertical, 10)
					.background(.thinMaterial)
				}
			}
		}
	}
}

#Preview("Default") {
	SessionForkMessagePickerView(
		messages: [
			PimuxSessionForkMessage(entryID: "msg-1", text: "Investigate why the build is failing after the database migration."),
			PimuxSessionForkMessage(entryID: "msg-2", text: "Let's instead prototype the UI first and keep the backend untouched."),
		],
		onSelect: { _ in },
		onCancel: {}
	)
}

#Preview("Submitting") {
	SessionForkMessagePickerView(
		messages: [
			PimuxSessionForkMessage(entryID: "msg-1", text: "Investigate why the build is failing after the database migration."),
		],
		isSubmitting: true,
		onSelect: { _ in },
		onCancel: {}
	)
}

#Preview("Error") {
	SessionForkMessagePickerView(
		messages: [
			PimuxSessionForkMessage(entryID: "msg-1", text: "Investigate why the build is failing after the database migration."),
		],
		errorMessage: "Timed out waiting for the host to create a fork.",
		onSelect: { _ in },
		onCancel: {}
	)
}
