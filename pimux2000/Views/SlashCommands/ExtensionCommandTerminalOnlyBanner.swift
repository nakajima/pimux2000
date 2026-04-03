import SwiftUI

struct ExtensionCommandTerminalOnlyBanner: View {
	let state: PimuxSessionTerminalOnlyUIState
	let onDismiss: () -> Void
	let onInterrupt: () -> Void

	private var title: String {
		switch state.kind {
		case "customUi":
			return "Terminal-only UI active"
		case "dialogFallback":
			return "Terminal fallback active"
		default:
			return "Unsupported iOS command UI"
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Label(title, systemImage: "terminal")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.primary)

			Text(verbatim: state.reason)
				.font(.footnote)
				.foregroundStyle(.secondary)

			HStack(spacing: 12) {
				Button("Dismiss", action: onDismiss)
					.buttonStyle(.borderless)

				Spacer()

				Button(action: onInterrupt) {
					Label("Interrupt", systemImage: "stop.circle")
				}
				.buttonStyle(.borderedProminent)
			}
		}
		.padding(12)
		.background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
		.overlay {
			RoundedRectangle(cornerRadius: 12)
				.stroke(.orange.opacity(0.35), lineWidth: 1)
		}
	}
}

#Preview("Custom UI") {
	ExtensionCommandTerminalOnlyBanner(
		state: PimuxSessionTerminalOnlyUIState(
			kind: "customUi",
			reason: "This extension command opened custom terminal UI that pimux iOS can’t render yet. Finish it in the Pi terminal, or interrupt the session."
		),
		onDismiss: {},
		onInterrupt: {}
	)
	.padding()
}

#Preview("Dialog fallback") {
	ExtensionCommandTerminalOnlyBanner(
		state: PimuxSessionTerminalOnlyUIState(
			kind: "dialogFallback",
			reason: "This command opened another interactive Pi dialog while one mirrored dialog was already active. Finish it in the terminal, or interrupt the session."
		),
		onDismiss: {},
		onInterrupt: {}
	)
	.padding()
}
