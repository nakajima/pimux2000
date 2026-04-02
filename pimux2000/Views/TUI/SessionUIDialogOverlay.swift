import SwiftUI

struct SessionUIDialogOverlay: View {
	let dialog: PimuxSessionUIDialogState
	let textValue: Binding<String>
	let isSendingAction: Bool
	let errorMessage: String?
	let onSelectOption: (Int) -> Void
	let onMoveSelection: (Int) -> Void
	let onSubmitSelector: () -> Void
	let onSubmitTextValue: () -> Void
	let onCancel: () -> Void
	@FocusState private var isKeyboardFocused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(dialog.title)
				.font(.headline)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)

			if !dialog.message.isEmpty {
				Text(dialog.message)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.fixedSize(horizontal: false, vertical: true)
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
		.frame(maxWidth: 560)
		.background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18))
		.overlay(
			RoundedRectangle(cornerRadius: 18)
				.stroke(Color.secondary.opacity(0.18), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.12), radius: 24, y: 8)
		.focusable()
		.focused($isKeyboardFocused)
		.onAppear {
			isKeyboardFocused = dialog.isSelectorDialog
		}
		.onChange(of: dialog.id) {
			isKeyboardFocused = dialog.isSelectorDialog
		}
		.onKeyPress(phases: [.down, .repeat]) { press in
			guard dialog.isSelectorDialog, !isSendingAction else { return .ignored }

			let isDown = press.key == .downArrow
				|| press.key == .rightArrow
				|| (press.key == KeyEquivalent("n") && press.modifiers.contains(.control))
			let isUp = press.key == .upArrow
				|| press.key == .leftArrow
				|| (press.key == KeyEquivalent("p") && press.modifiers.contains(.control))

			if isDown {
				onMoveSelection(1)
				return .handled
			}
			if isUp {
				onMoveSelection(-1)
				return .handled
			}
			if press.key == .return {
				onSubmitSelector()
				return .handled
			}
			if press.key == .escape {
				onCancel()
				return .handled
			}

			return .ignored
		}
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
			onMoveSelection: { _ in },
			onSubmitSelector: {},
			onSubmitTextValue: {},
			onCancel: {}
		)
		.padding()
	}
}

#Preview("Session UI select dialog — long content") {
	ZStack {
		Color(.systemBackground)
		SessionUIDialogOverlay(
			dialog: PimuxSessionUIDialogState(
				id: "select-1",
				kind: "select",
				title: "Question 5/6: The existing `/pimux` command has `resummarize` as a subcommand. Should the update command be `/pimux update` (matching the CLI), or a different name?",
				message: "Pick the option that feels most consistent. Long choices should stay readable without truncation.",
				options: [
					"/pimux update (subcommand of existing `/pimux` command, matching the CLI naming and keeping related actions grouped together)",
					"/pimux-update (separate top-level command that is shorter to type but less aligned with the existing command namespace)",
					"None of these / something else",
				],
				selectedIndex: 0,
				placeholder: nil,
				value: nil
			),
			textValue: .constant(""),
			isSendingAction: false,
			errorMessage: nil,
			onSelectOption: { _ in },
			onMoveSelection: { _ in },
			onSubmitSelector: {},
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
			onMoveSelection: { _ in },
			onSubmitSelector: {},
			onSubmitTextValue: {},
			onCancel: {}
		)
		.padding()
	}
}
