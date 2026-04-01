import SwiftUI

struct SessionUISelectorDialogContent: View {
	let dialog: PimuxSessionUIDialogState
	let isSendingAction: Bool
	let onSelectOption: (Int) -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(spacing: 10) {
				ForEach(Array(dialog.options.enumerated()), id: \.offset) { index, option in
					Button {
						onSelectOption(index)
					} label: {
						HStack(spacing: 12) {
							Text(option)
								.fontWeight(dialog.selectedIndex == index ? .semibold : .regular)
							Spacer()
							if dialog.selectedIndex == index {
								Image(systemName: "checkmark.circle.fill")
									.foregroundStyle(.tint)
							}
						}
						.padding(.horizontal, 14)
						.padding(.vertical, 12)
						.frame(maxWidth: .infinity)
						.background(
							dialog.selectedIndex == index
								? AnyShapeStyle(.tint.opacity(0.14))
								: AnyShapeStyle(.regularMaterial),
							in: RoundedRectangle(cornerRadius: 12)
						)
						.overlay(
							RoundedRectangle(cornerRadius: 12)
								.stroke(dialog.selectedIndex == index ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
						)
					}
					.buttonStyle(.plain)
					.disabled(isSendingAction)
				}
			}

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
