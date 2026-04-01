import SwiftUI

struct SessionUIDialogOverlay: View {
	let dialog: PimuxSessionUIDialogState
	let textValue: Binding<String>
	let isSendingAction: Bool
	let errorMessage: String?
	let onSelectOption: (Int) -> Void
	let onSubmitTextValue: () -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(dialog.title)
				.font(.headline)

			if !dialog.message.isEmpty {
				Text(dialog.message)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}

			if dialog.isTextValueDialog {
				SessionUITextValueDialogContent(
					dialog: dialog,
					textValue: textValue,
					isSendingAction: isSendingAction,
					onSubmitTextValue: onSubmitTextValue,
					onCancel: onCancel
				)
			} else {
				SessionUISelectorDialogContent(
					dialog: dialog,
					isSendingAction: isSendingAction,
					onSelectOption: onSelectOption,
					onCancel: onCancel
				)
			}

			if isSendingAction {
				HStack(spacing: 8) {
					ProgressView()
						.controlSize(.small)
					Text("Sending action…")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			if let errorMessage, !errorMessage.isEmpty {
				Text(verbatim: errorMessage)
					.font(.caption)
					.foregroundStyle(.red)
			}
		}
		.padding(20)
		.frame(maxWidth: 420)
		.background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18))
		.overlay(
			RoundedRectangle(cornerRadius: 18)
				.stroke(Color.secondary.opacity(0.18), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.12), radius: 24, y: 8)
	}
}

#Preview("Session UI confirm dialog") {
	ZStack {
		Color(.systemBackground)
		SessionUIDialogOverlay(
			dialog: PimuxSessionUIDialogState(
				id: "confirm-1",
				kind: "confirm",
				title: "Pimux Live Confirm Test",
				message: "Choose from either the Pi TUI or the iOS app. Does this confirm stay mirrored and resolve correctly?",
				options: ["Yes", "No"],
				selectedIndex: 0,
				placeholder: nil,
				value: nil
			),
			textValue: .constant(""),
			isSendingAction: false,
			errorMessage: nil,
			onSelectOption: { _ in },
			onSubmitTextValue: {},
			onCancel: {}
		)
		.padding()
	}
}

#Preview("Session UI editor dialog") {
	ZStack {
		Color(.systemBackground)
		SessionUIDialogOverlay(
			dialog: PimuxSessionUIDialogState(
				id: "editor-1",
				kind: "editor",
				title: "Pimux Live Editor Test",
				message: "",
				options: [],
				selectedIndex: 0,
				placeholder: nil,
				value: "Edit this text from either the Pi TUI or the iOS app.\n\nDoes this editor stay mirrored and resolve correctly?"
			),
			textValue: .constant("Edit this text from either the Pi TUI or the iOS app.\n\nDoes this editor stay mirrored and resolve correctly?"),
			isSendingAction: false,
			errorMessage: nil,
			onSelectOption: { _ in },
			onSubmitTextValue: {},
			onCancel: {}
		)
		.padding()
	}
}
