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
	func collapsesPreviewWhenMessageHasMoreThanTenLines() {
		let text = (1...11).map { "line \($0)" }.joined(separator: "\n")

		#expect(MessageMarkdownRenderer.shouldCollapsePreview(for: text))
	}

	@Test
	func keepsShortMessagesExpanded() {
		#expect(!MessageMarkdownRenderer.shouldCollapsePreview(for: "short message"))
	}

	@Test
	func previewTextTrimsLongMessagesBeforeRenderingListPreview() {
		let text = (1...20).map { "line \($0)" }.joined(separator: "\n")

		#expect(MessageMarkdownRenderer.previewText(for: text).count <= 900)
	}
}
