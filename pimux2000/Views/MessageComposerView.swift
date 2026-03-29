import SwiftUI

struct MessageComposerView: View {
	@Binding var text: String
	var customCommands: [PimuxSessionCommand] = []
	var placeholder: String = "Send a message"
	var isEnabled: Bool = true
	var isSending: Bool = false
	var errorMessage: String? = nil
	var onSend: () -> Void

	private var trimmedText: String {
		text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private var canSend: Bool {
		isEnabled && !isSending && !trimmedText.isEmpty
	}

	private var allCommands: [SlashCommand] {
		SlashCommand.merged(custom: customCommands)
	}

	private var matchingCommands: [SlashCommand] {
		// Only match when the text is purely a slash prefix (no spaces yet)
		let trimmed = trimmedText
		guard trimmed.hasPrefix("/"), !trimmed.dropFirst().contains(" ") else { return [] }
		return SlashCommand.matching(query: trimmed, from: allCommands)
	}

	var body: some View {
		VStack(spacing: 0) {
			Divider()

			VStack(alignment: .leading, spacing: 8) {
				if !matchingCommands.isEmpty {
					SlashCommandMenuView(commands: matchingCommands) { command in
						text = command.displayName + " "
					}
					.transition(.move(edge: .bottom).combined(with: .opacity))
				}

				if let errorMessage, !errorMessage.isEmpty {
					Label {
						Text(verbatim: errorMessage)
					} icon: {
						Image(systemName: "exclamationmark.triangle.fill")
					}
						.font(.caption)
						.foregroundStyle(.red)
				}

				HStack(alignment: .bottom, spacing: 12) {
					TextField(placeholder, text: $text, axis: .vertical)
						.lineLimit(1 ... 6)
						#if os(iOS)
						.textInputAutocapitalization(.sentences)
						#endif
						.padding(.horizontal, 12)
						.padding(.vertical, 10)
						.background(.background, in: RoundedRectangle(cornerRadius: 12))
						.disabled(!isEnabled || isSending)

					Button(action: onSend) {
						if isSending {
							ProgressView()
								.controlSize(.small)
								.frame(width: 28, height: 28)
						} else {
							Image(systemName: "arrow.up.circle.fill")
								.font(.system(size: 28))
						}
					}
					.buttonStyle(.plain)
					.keyboardShortcut(.return, modifiers: [.command])
					.disabled(!canSend)
					.accessibilityLabel("Send message")
				}
			}
			.padding(.horizontal)
			.padding(.vertical, 12)
			.background(.thinMaterial)
			.animation(.easeOut(duration: 0.15), value: matchingCommands.map(\.name))
		}
	}
}

// MARK: - Slash Command Menu

private struct SlashCommandMenuView: View {
	let commands: [SlashCommand]
	let onSelect: (SlashCommand) -> Void

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(commands) { command in
					Button {
						onSelect(command)
					} label: {
						HStack(spacing: 8) {
							Text(command.displayName)
								.fontWeight(.medium)
								.foregroundStyle(.primary)
							Text(command.description)
								.foregroundStyle(.secondary)
								.lineLimit(1)
							Spacer()
						}
						.font(.callout)
						.padding(.horizontal, 12)
						.padding(.vertical, 8)
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
				}
			}
		}
		.frame(maxHeight: 200)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
	}
}

private struct MessageComposerPreviewHost: View {
	@State var text: String
	var isEnabled: Bool = true
	var isSending: Bool = false
	var errorMessage: String? = nil

	var body: some View {
		VStack(spacing: 0) {
			Spacer()

			MessageComposerView(
				text: $text,
				isEnabled: isEnabled,
				isSending: isSending,
				errorMessage: errorMessage,
				onSend: {}
			)
		}
		.background(.background)
	}
}

#Preview("Ready") {
	MessageComposerPreviewHost(text: "Continue from here")
}

#Preview("Slash commands") {
	MessageComposerPreviewHost(text: "/")
}

#Preview("Slash filter") {
	MessageComposerPreviewHost(text: "/co")
}

#Preview("Sending") {
	MessageComposerPreviewHost(text: "Continue from here", isSending: true)
}

#Preview("Error") {
	MessageComposerPreviewHost(
		text: "",
		isEnabled: true,
		errorMessage: "Timed out waiting for host confirmation."
	)
}
