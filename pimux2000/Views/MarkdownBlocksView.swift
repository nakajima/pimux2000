import SwiftUI

private struct MarkdownTextStyleKey: EnvironmentKey {
	static let defaultValue: Font.TextStyle = .body
}

extension EnvironmentValues {
	var markdownTextStyle: Font.TextStyle {
		get { self[MarkdownTextStyleKey.self] }
		set { self[MarkdownTextStyleKey.self] = newValue }
	}
}

struct MarkdownBlocksView: View {
	let blocks: [MarkdownBlock]
	var isSelectable: Bool = false
	@Environment(\.markdownTextStyle) private var textStyle

	private var baseFont: UIFont { chatUIFont(style: textStyle) }

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
				blockView(for: block)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	@ViewBuilder
	private func blockView(for block: MarkdownBlock) -> some View {
		switch block {
		case .paragraph(let text):
			inlineTextView(for: text)

		case .heading(let level, let text):
			headingView(level: level, text: text)

		case .codeBlock(let language, let code):
			CodeBlockView(language: language, code: code)

		case .blockQuote(let content):
			BlockQuoteView(content: content, isSelectable: isSelectable)

		case .unorderedList(let items):
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Array(items.enumerated()), id: \.offset) { _, item in
					HStack(alignment: .firstTextBaseline, spacing: 6) {
						Text("•")
							.foregroundStyle(.secondary)
						inlineTextView(for: item)
					}
				}
			}

		case .orderedList(let items):
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Array(items.enumerated()), id: \.offset) { _, item in
					HStack(alignment: .firstTextBaseline, spacing: 6) {
						Text("\(item.ordinal).")
							.foregroundStyle(.secondary)
							.monospacedDigit()
						inlineTextView(for: item.text)
					}
				}
			}


		case .thematicBreak:
			Divider()
				.padding(.vertical, 4)
		}
	}

	private func inlineTextView(for text: String) -> some View {
		MarkdownTextView(
			attributedText: MarkdownAttributedStringBuilder.inlineAttributedString(for: text, font: baseFont),
			isSelectable: isSelectable
		)
	}

	@ViewBuilder
	private func headingView(level: Int, text: String) -> some View {
		let scale: CGFloat = switch level {
		case 1: 1.4
		case 2: 1.25
		case 3: 1.12
		default: 1.05
		}
		let font = UIFont.systemFont(
			ofSize: baseFont.pointSize * scale,
			weight: .semibold
		)

		MarkdownTextView(
			attributedText: MarkdownAttributedStringBuilder.inlineAttributedString(
				for: text,
				font: font
			),
			isSelectable: isSelectable
		)
		.padding(.top, level <= 2 ? 6 : 2)
	}
}

// MARK: - Code block

private struct CodeBlockView: View {
	let language: String?
	let code: String

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if let language, !language.isEmpty {
				Text(language)
					.font(.caption2.weight(.medium))
					.foregroundStyle(.tertiary)
					.padding(.top, 8)
					.padding(.horizontal, 10)
			}

			Text(verbatim: code)
				.font(.system(.callout, design: .monospaced))
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(10)
		}
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
	}
}

// MARK: - Block quote

private struct BlockQuoteView: View {
	let content: String
	var isSelectable: Bool = false
	@Environment(\.markdownTextStyle) private var textStyle

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			RoundedRectangle(cornerRadius: 1.5)
				.fill(.secondary.opacity(0.4))
				.frame(width: 3)

			MarkdownTextView(
				attributedText: MarkdownAttributedStringBuilder.inlineAttributedString(
					for: content,
					font: chatUIFont(style: textStyle),
					textColor: .secondaryLabel
				),
				isSelectable: isSelectable
			)
		}
	}
}
