import SwiftUI
import Textual

struct MessageMarkdownView: View {
	enum DisplayMode {
		case preview
		case full
	}

	let text: String
	let role: Message.Role
	let title: String
	var displayMode: DisplayMode = .preview

	private var previewHeight: CGFloat {
		ceil(chatLineHeight(style: .body) * CGFloat(MessageMarkdownRenderer.maxPreviewLines))
	}

	private var shouldCollapsePreview: Bool {
		displayMode == .preview && MessageMarkdownRenderer.shouldCollapsePreview(for: text)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if shouldCollapsePreview {
				collapsedPreview
					.frame(maxHeight: previewHeight, alignment: .top)
					.clipped()
					.overlay(alignment: .bottom, content: previewFade)

				NavigationLink(value: Route.messageContext(route)) {
					Label("View full context", systemImage: "arrow.right.circle")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.tint)
				}
				.buttonStyle(.plain)
			} else {
				renderedMarkdown
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var route: MessageContextRoute {
		MessageContextRoute(title: title, text: text, role: role)
	}

	private var renderedMarkdown: some View {
		StructuredText(markdown: MessageMarkdownRenderer.markdown(for: text, role: role))
			.font(chatFont(style: .body))
			.textual.structuredTextStyle(.gitHub)
			.textual.highlighterTheme(.default)
			.applyIf(displayMode == .full) { view in
				view.textual.textSelection(.enabled)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var collapsedPreview: some View {
		Text(verbatim: MessageMarkdownRenderer.previewText(for: text))
			.font(chatFont(style: .body))
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func previewFade() -> some View {
		Rectangle()
			.fill(.background)
			.frame(height: chatLineHeight(style: .body) * 2)
			.mask(
				LinearGradient(
					colors: [.clear, .black],
					startPoint: .top,
					endPoint: .bottom
				)
			)
			.allowsHitTesting(false)
	}
}

struct MessageContextView: View {
	let route: MessageContextRoute

	var body: some View {
		ScrollView {
			MessageMarkdownView(
				text: route.text,
				role: route.role,
				title: route.title,
				displayMode: .full
			)
			.padding()
		}
		.navigationTitle(route.title)
		#if os(iOS)
		.navigationBarTitleDisplayMode(.inline)
		#endif
		.background(.background)
	}
}

enum MessageMarkdownRenderer {
	static let maxPreviewLines = 10
	private static let maxPreviewCharacters = 900

	static func markdown(for text: String, role: Message.Role) -> String {
		guard role == .toolResult else { return text }

		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !text.contains("```") else { return text }

		let openingFence = inferredLanguage(for: text).map { "```\($0)" } ?? "```"
		let code = text.hasSuffix("\n") ? String(text.dropLast()) : text
		return "\(openingFence)\n\(code)\n```"
	}

	static func shouldCollapsePreview(for text: String) -> Bool {
		let lineCount = text.components(separatedBy: .newlines).count
		return lineCount > maxPreviewLines || text.count > maxPreviewCharacters
	}

	static func previewText(for text: String) -> String {
		let limitedLines = text
			.components(separatedBy: .newlines)
			.prefix(maxPreviewLines + 2)
			.joined(separator: "\n")
		return String(limitedLines.prefix(maxPreviewCharacters))
	}

	static func inferredLanguage(for text: String) -> String? {
		let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !sample.isEmpty else { return nil }

		let lowered = sample.lowercased()

		if sample.first == "{" || sample.first == "[" {
			return "json"
		}

		if sample.first == "<" {
			return "html"
		}

		if lowered.contains("#!/bin/")
			|| lowered.contains("\necho ")
			|| lowered.contains("\nexport ")
			|| lowered.contains("\nfi")
			|| lowered.contains("\ndone") {
			return "bash"
		}

		if lowered.contains("import swiftui")
			|| lowered.contains("import foundation")
			|| lowered.contains("\nstruct ")
			|| lowered.contains("\nenum ")
			|| lowered.contains("\nprotocol ")
			|| lowered.contains("\nfunc ")
			|| lowered.contains("@main") {
			return "swift"
		}

		if lowered.contains("\nconst ")
			|| lowered.contains("\nfunction ")
			|| lowered.contains("console.log")
			|| lowered.contains("=>") {
			return "javascript"
		}

		if lowered.contains("\ndef ")
			|| lowered.contains("if __name__")
			|| lowered.contains("print(") {
			return "python"
		}

		if lowered.contains("select ")
			|| lowered.contains("insert into ")
			|| lowered.contains("create table ")
			|| lowered.contains("update ")
			|| lowered.contains("delete from ") {
			return "sql"
		}

		return nil
	}
}

private extension View {
	@ViewBuilder
	func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
		if condition {
			transform(self)
		} else {
			self
		}
	}
}
