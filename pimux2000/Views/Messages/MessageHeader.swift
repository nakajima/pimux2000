import SwiftUI

func shortToolCallLabel(_ value: String) -> String {
	let trimmed = value.split(separator: "|", maxSplits: 1).first.map(String.init) ?? value
	guard trimmed.count > 18 else { return trimmed }
	return String(trimmed.prefix(18)) + "…"
}

struct MessageHeader: View {
	let icon: String
	let label: String
	let color: Color
	var toolName: String? = nil
	var detailText: String? = nil

	var body: some View {
		HStack(spacing: 6) {
			Text(verbatim: label)
				.font(.caption)
				.fontWeight(.semibold)
				.textCase(.uppercase)

			if let toolName {
				Text(verbatim: "· \(toolName)")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			if let detailText {
				Text(verbatim: "· \(detailText)")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.foregroundStyle(color)
	}
}

#Preview {
	VStack(alignment: .leading, spacing: 12) {
		MessageHeader(icon: "person.fill", label: "You", color: .blue)
		MessageHeader(icon: "sparkles", label: "Assistant", color: .purple)
		MessageHeader(icon: "wrench.fill", label: "Tool Result", color: .orange, toolName: "read")
	}
	.padding()
}
