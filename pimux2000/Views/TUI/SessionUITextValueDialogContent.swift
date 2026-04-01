import SwiftUI

struct SessionUITextValueDialogContent: View {
	let dialog: PimuxSessionUIDialogState
	let textValue: Binding<String>
	let isSendingAction: Bool
	let onSubmitTextValue: () -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			if dialog.usesMultilineTextEditor {
				TextEditor(text: textValue)
					.font(.system(.body, design: .monospaced))
					.frame(minHeight: 220)
					.padding(8)
					.background(
						RoundedRectangle(cornerRadius: 12)
							.fill(.regularMaterial)
					)
					.overlay(
						RoundedRectangle(cornerRadius: 12)
							.stroke(Color.secondary.opacity(0.18), lineWidth: 1)
					)
					.disabled(isSendingAction)
			} else {
				TextField(dialog.placeholder ?? "", text: textValue)
					.textFieldStyle(.roundedBorder)
					.submitLabel(.done)
					.disabled(isSendingAction)
					.onSubmit(onSubmitTextValue)
			}

			HStack {
				Spacer()
				Button("Cancel", role: .cancel, action: onCancel)
					.disabled(isSendingAction)
				Button("Submit", action: onSubmitTextValue)
					.disabled(isSendingAction)
			}
		}
	}
}

#Preview("Input dialog content") {
	ZStack {
		Color(.systemBackground)
		SessionUITextValueDialogContent(
			dialog: PimuxSessionUIDialogState(
				id: "input-1",
				kind: "input",
				title: "Pimux Live Input Test",
				message: "",
				options: [],
				selectedIndex: 0,
				placeholder: "Type from either the Pi TUI or the iOS app.",
				value: "hello"
			),
			textValue: .constant("hello"),
			isSendingAction: false,
			onSubmitTextValue: {},
			onCancel: {}
		)
		.padding()
	}
}

#Preview("Editor dialog content") {
	ZStack {
		Color(.systemBackground)
		SessionUITextValueDialogContent(
			dialog: PimuxSessionUIDialogState(
				id: "editor-1",
				kind: "editor",
				title: "Pimux Live Editor Test",
				message: "",
				options: [],
				selectedIndex: 0,
				placeholder: nil,
				value: "Edit this text from either the Pi TUI or the iOS app."
			),
			textValue: .constant("Edit this text from either the Pi TUI or the iOS app."),
			isSendingAction: false,
			onSubmitTextValue: {},
			onCancel: {}
		)
		.padding()
	}
}
