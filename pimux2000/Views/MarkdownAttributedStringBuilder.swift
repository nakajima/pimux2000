import UIKit

enum MarkdownAttributedStringBuilder {

	/// Full attributed string for a message — handles monospaced roles and inline-only text.
	/// Block-level markdown is handled by ``MarkdownBlocksView`` instead.
	static func attributedString(for text: String, role: Message.Role, font: UIFont = chatUIFont()) -> NSAttributedString {
		let baseFont = font
		let monoFont = UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
		let textColor = UIColor.label
		let isMonospaced = role == .toolResult || role == .bashExecution

		if isMonospaced {
			return NSAttributedString(string: text, attributes: [
				.font: monoFont,
				.foregroundColor: textColor,
			])
		}

		let markup = MessageMarkdownRenderer.markdown(for: text, role: role)
		return renderInline(markup, font: baseFont, monoFont: monoFont, textColor: textColor)
	}

	/// Inline-only attributed string for use inside block views (paragraphs, headings, list items, quotes).
	static func inlineAttributedString(
		for text: String,
		font: UIFont = chatUIFont(),
		textColor: UIColor = .label
	) -> NSAttributedString {
		let monoFont = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
		return renderInline(text, font: font, monoFont: monoFont, textColor: textColor)
	}

	// MARK: - Private

	private static func renderInline(
		_ markup: String,
		font: UIFont,
		monoFont: UIFont,
		textColor: UIColor
	) -> NSAttributedString {
		do {
			let options = AttributedString.MarkdownParsingOptions(
				interpretedSyntax: .inlineOnlyPreservingWhitespace
			)
			var source = try AttributedString(markdown: markup, options: options)

			source.uiKit.font = font
			source.uiKit.foregroundColor = textColor

			applyInlineStyling(to: &source, baseFont: font, monoFont: monoFont)

			return NSAttributedString(source)
		} catch {
			var container = AttributeContainer()
			container.uiKit.font = font
			container.uiKit.foregroundColor = textColor
			return NSAttributedString(AttributedString(markup, attributes: container))
		}
	}

	// MARK: - Inline styling

	private struct InlineMod {
		let range: Range<AttributedString.Index>
		var font: UIFont?
		var backgroundColor: UIColor?
		var strikethrough: Bool = false
	}

	private static func applyInlineStyling(
		to source: inout AttributedString,
		baseFont: UIFont,
		monoFont: UIFont
	) {
		var mods: [InlineMod] = []

		for (intent, range) in source.runs[\.inlinePresentationIntent] {
			guard let intent else { continue }

			if intent.contains(.code) {
				mods.append(InlineMod(
					range: range,
					font: monoFont,
					backgroundColor: UIColor.tertiarySystemFill
				))
				continue
			}

			let currentFont = source[range].uiKit.font ?? baseFont
			var traits = currentFont.fontDescriptor.symbolicTraits

			if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
			if intent.contains(.emphasized) { traits.insert(.traitItalic) }

			var font: UIFont?
			if traits != currentFont.fontDescriptor.symbolicTraits,
				let descriptor = currentFont.fontDescriptor.withSymbolicTraits(traits)
			{
				font = UIFont(descriptor: descriptor, size: currentFont.pointSize)
			}

			mods.append(InlineMod(
				range: range,
				font: font,
				strikethrough: intent.contains(.strikethrough)
			))
		}

		for mod in mods {
			if let font = mod.font { source[mod.range].uiKit.font = font }
			if let bg = mod.backgroundColor { source[mod.range].uiKit.backgroundColor = bg }
			if mod.strikethrough { source[mod.range].uiKit.strikethroughStyle = .single }
		}
	}
}
