@testable import pimux2000
import Testing

struct MessageMarkdownRendererTests {
	@Test
	func leavesAssistantMarkdownUntouched() {
		let markdown = """
		Here is some Swift:

		```swift
		let answer = 42
		```
		"""

		#expect(
			MessageMarkdownRenderer.markdown(for: markdown, role: .assistant) == markdown
		)
	}

	@Test
	func wrapsToolResultsInFencedCodeBlocks() {
		let source = """
		import SwiftUI

		struct DemoView: View {
			var body: some View { Text("Hi") }
		}
		"""

		let rendered = MessageMarkdownRenderer.markdown(for: source, role: .toolResult)

		#expect(rendered.hasPrefix("```swift\n"))
		#expect(rendered.hasSuffix("\n```"))
	}

	@Test
	func preservesExistingFencedToolResults() {
		let markdown = """
		```json
		{"ok":true}
		```
		"""

		#expect(
			MessageMarkdownRenderer.markdown(for: markdown, role: .toolResult) == markdown
		)
	}

	@Test
	func collapsesPreviewForLongToolResults() {
		let text = (1...11).map { "line \($0)" }.joined(separator: "\n")

		#expect(MessageMarkdownRenderer.shouldCollapsePreview(for: text, role: .toolResult))
	}

	@Test
	func keepsUserMessagesExpandedEvenWhenLong() {
		let text = (1...30).map { "line \($0)" }.joined(separator: "\n")

		#expect(!MessageMarkdownRenderer.shouldCollapsePreview(for: text, role: .user))
		#expect(!MessageMarkdownRenderer.shouldCollapsePreview(for: text, role: .assistant))
	}

	@Test
	func keepsShortMessagesExpanded() {
		#expect(!MessageMarkdownRenderer.shouldCollapsePreview(for: "short message", role: .toolResult))
	}

	@Test
	func previewTextTrimsLongMessagesBeforeRenderingListPreview() {
		let text = (1...20).map { "line \($0)" }.joined(separator: "\n")

		#expect(MessageMarkdownRenderer.previewText(for: text).count <= 900)
	}

	@Test
	func wrapsBashExecutionsInFencedCodeBlocks() {
		let source = "$ echo hi\nhi"

		let rendered = MessageMarkdownRenderer.markdown(for: source, role: .bashExecution)

		#expect(rendered.hasPrefix("```bash\n"))
		#expect(rendered.hasSuffix("\n```"))
	}

	@Test
	func usesInlineMarkdownForPlainMultilineText() {
		let text = "first line\nsecond line"

		#expect(MessageMarkdownRenderer.usesInlineMarkdown(for: text, role: .assistant))
	}

	@Test
	func preservesPlainMultilineLineBreaksInRenderedMarkdown() {
		let text = "first line\nsecond line"

		#expect(
			MessageMarkdownRenderer.markdown(for: text, role: .assistant)
				== "first line  \nsecond line"
		)
	}

	@Test
	func preservesBlankLinesBetweenParagraphsInRenderedMarkdown() {
		let text = "first paragraph\n\nsecond paragraph"

		#expect(
			MessageMarkdownRenderer.markdown(for: text, role: .assistant)
				== text
		)
	}

	@Test
	func usesBlockMarkdownForLists() {
		let text = "1. one\n2. two"

		#expect(!MessageMarkdownRenderer.usesInlineMarkdown(for: text, role: .assistant))
	}
}
