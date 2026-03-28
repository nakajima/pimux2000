import SwiftUI

struct MessageComposerView: View {
	@Binding var text: String
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

	var body: some View {
		VStack(spacing: 0) {
			Divider()

			VStack(alignment: .leading, spacing: 8) {
				if let errorMessage, !errorMessage.isEmpty {
					Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
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
		}
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
