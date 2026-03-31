import UIKit

enum MarkdownAttributedStringBuilder {

	static func attributedString(for text: String, role: Message.Role) -> NSAttributedString {
		let baseFont = chatUIFont()
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
		let isInlineOnly = MessageMarkdownRenderer.usesInlineMarkdown(for: text, role: role)

		return renderMarkdown(
			markup,
			isInlineOnly: isInlineOnly,
			baseFont: baseFont,
			monoFont: monoFont,
			textColor: textColor
		)
	}

	// MARK: - Private

	private static func renderMarkdown(
		_ markup: String,
		isInlineOnly: Bool,
		baseFont: UIFont,
		monoFont: UIFont,
		textColor: UIColor
	) -> NSAttributedString {
		do {
			let syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax =
				isInlineOnly ? .inlineOnlyPreservingWhitespace : .full
			let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: syntax)
			var source = try AttributedString(markdown: markup, options: options)

			// Set base styling on entire string
			source.uiKit.font = baseFont
			source.uiKit.foregroundColor = textColor

			if !isInlineOnly {
				applyBlockStyling(
					to: &source,
					baseFont: baseFont,
					monoFont: monoFont,
					textColor: textColor
				)
			}

			applyInlineStyling(to: &source, baseFont: baseFont, monoFont: monoFont)

			return NSAttributedString(source)
		} catch {
			var container = AttributeContainer()
			container.uiKit.font = baseFont
			container.uiKit.foregroundColor = textColor
			return NSAttributedString(AttributedString(markup, attributes: container))
		}
	}

	// MARK: - Block styling

	private struct BlockMod {
		let range: Range<AttributedString.Index>
		var font: UIFont?
		var foregroundColor: UIColor?
		var backgroundColor: UIColor?
	}

	private static func applyBlockStyling(
		to source: inout AttributedString,
		baseFont: UIFont,
		monoFont: UIFont,
		textColor: UIColor
	) {
		var mods: [BlockMod] = []
		var listMarkers: [(index: AttributedString.Index, marker: String)] = []

		for (intent, range) in source.runs[\.presentationIntent] {
			guard let intent else { continue }

			for component in intent.components {
				switch component.kind {
				case .header(let level):
					let scale: CGFloat = switch level {
					case 1: 1.4
					case 2: 1.25
					case 3: 1.12
					default: 1.05
					}
					mods.append(BlockMod(
						range: range,
						font: UIFont.systemFont(ofSize: baseFont.pointSize * scale, weight: .semibold)
					))

				case .codeBlock:
					mods.append(BlockMod(
						range: range,
						font: UIFont.monospacedSystemFont(
							ofSize: monoFont.pointSize * 0.9,
							weight: .regular
						),
						backgroundColor: UIColor.tertiarySystemFill
					))

				case .blockQuote:
					mods.append(BlockMod(
						range: range,
						foregroundColor: UIColor.secondaryLabel
					))

				case .listItem(let ordinal):
					let isOrdered = intent.components.contains { c in
						if case .orderedList = c.kind { return true }
						return false
					}
					let marker = isOrdered ? "\(ordinal).\t" : "•\t"
					listMarkers.append((index: range.lowerBound, marker: marker))

				default:
					break
				}
			}
		}

		// Apply attribute modifications (no character changes, so ranges stay valid).
		for mod in mods {
			if let font = mod.font { source[mod.range].uiKit.font = font }
			if let fg = mod.foregroundColor { source[mod.range].uiKit.foregroundColor = fg }
			if let bg = mod.backgroundColor { source[mod.range].uiKit.backgroundColor = bg }
		}

		// Insert list markers in reverse so earlier insertions don't shift later indices.
		var markerAttrs = AttributeContainer()
		markerAttrs.uiKit.font = baseFont
		markerAttrs.uiKit.foregroundColor = textColor

		for insertion in listMarkers.reversed() {
			source.insert(
				AttributedString(insertion.marker, attributes: markerAttrs),
				at: insertion.index
			)
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
