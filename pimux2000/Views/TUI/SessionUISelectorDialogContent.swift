import SwiftUI

struct SessionUISelectorDialogContent: View {
	let dialog: PimuxSessionUIDialogState
	let isSendingAction: Bool
	let onSelectOption: (Int) -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			ScrollView {
				VStack(spacing: 10) {
					ForEach(Array(dialog.options.enumerated()), id: \.offset) { index, option in
						Button {
							onSelectOption(index)
						} label: {
							Text(option)
								.fontWeight(dialog.selectedIndex == index ? .semibold : .regular)
								.multilineTextAlignment(.leading)
								.fixedSize(horizontal: false, vertical: true)
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(.trailing, dialog.selectedIndex == index ? 34 : 0)
								.padding(.horizontal, 14)
								.padding(.vertical, 12)
								.background(
									dialog.selectedIndex == index
										? AnyShapeStyle(.tint.opacity(0.14))
										: AnyShapeStyle(.regularMaterial),
									in: RoundedRectangle(cornerRadius: 12)
								)
								.overlay(alignment: .topTrailing) {
									if dialog.selectedIndex == index {
										Image(systemName: "checkmark.circle.fill")
											.foregroundStyle(.tint)
											.padding(.top, 12)
											.padding(.trailing, 14)
									}
								}
								.overlay(
									RoundedRectangle(cornerRadius: 12)
										.stroke(dialog.selectedIndex == index ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
								)
						}
						.buttonStyle(.plain)
						.disabled(isSendingAction)
					}
				}
			}
			.frame(maxHeight: 320)

			HStack {
				Spacer()
				Button("Cancel", role: .cancel, action: onCancel)
					.disabled(isSendingAction)
			}
		}
	}
}

#Preview("Selector dialog content") {
	ZStack {
		Color(.systemBackground)
		SessionUISelectorDialogContent(
			dialog: PimuxSessionUIDialogState(
				id: "select-1",
				kind: "select",
				title: "Pimux Live Select Test",
				message: "",
				options: ["Alpha", "Beta", "Gamma"],
				selectedIndex: 1,
				placeholder: nil,
				value: nil
			),
			isSendingAction: false,
			onSelectOption: { _ in },
			onCancel: {}
		)
		.padding()
	}
}

#Preview("Selector dialog content — long options") {
	ZStack {
		Color(.systemBackground)
		SessionUISelectorDialogContent(
			dialog: PimuxSessionUIDialogState(
				id: "select-long-1",
				kind: "select",
				title: "Long selector test",
				message: "",
				options: [
					"/pimux update (subcommand of existing `/pimux` command, matching the CLI naming and keeping related actions grouped together)",
					"/pimux-update (separate top-level command that is shorter to type but less aligned with the existing command namespace)",
					"None of these / something else",
				],
				selectedIndex: 0,
				placeholder: nil,
				value: nil
			),
			isSendingAction: false,
			onSelectOption: { _ in },
			onCancel: {}
		)
		.padding()
	}
}
