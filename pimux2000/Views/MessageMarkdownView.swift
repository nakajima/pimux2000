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
		displayMode == .preview && MessageMarkdownRenderer.shouldCollapsePreview(for: text, role: role)
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
		let markup = MessageMarkdownRenderer.markdown(for: text, role: role)
		let usesInlineMarkdown = MessageMarkdownRenderer.usesInlineMarkdown(for: text, role: role)

		let isMonospaced = role == .toolResult || role == .bashExecution

		return Group {
			if usesInlineMarkdown {
				StructuredText(markup, parser: .inlineMarkdown())
			} else {
				StructuredText(markdown: markup)
			}
		}
		.font(isMonospaced ? .system(.body, design: .monospaced) : chatFont(style: .body))
		.textual.structuredTextStyle(.gitHub)
		.textual.highlighterTheme(.default)
		.applyIf(displayMode == .full) { view in
			view.textual.textSelection(.enabled)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var collapsedPreview: some View {
		let isMonospaced = role == .toolResult || role == .bashExecution

		return Text(verbatim: MessageMarkdownRenderer.previewText(for: text))
			.font(isMonospaced ? .system(.body, design: .monospaced) : chatFont(style: .body))
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
		switch role {
		case .toolResult:
			return fencedBlockIfNeeded(text: text, language: inferredLanguage(for: text))
		case .bashExecution:
			return fencedBlockIfNeeded(text: text, language: "bash")
		default:
			return usesInlineMarkdown(for: text, role: role) ? preservingInlineLineBreaks(in: text) : text
		}
	}

	static func usesInlineMarkdown(for text: String, role: Message.Role) -> Bool {
		switch role {
		case .toolResult, .bashExecution:
			return false
		default:
			return !containsBlockMarkdown(text)
		}
	}

	private static func fencedBlockIfNeeded(text: String, language: String?) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !text.contains("```") else { return text }

		let openingFence = language.map { "```\($0)" } ?? "```"
		let code = text.hasSuffix("\n") ? String(text.dropLast()) : text
		return "\(openingFence)\n\(code)\n```"
	}

	private static func preservingInlineLineBreaks(in text: String) -> String {
		let normalized = text
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
		let lines = normalized.components(separatedBy: .newlines)
		guard lines.count > 1 else { return normalized }

		var result = ""
		for index in lines.indices {
			let line = lines[index]
			result += line

			guard index < lines.index(before: lines.endIndex) else { continue }
			let currentIsBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
			let nextLine = lines[lines.index(after: index)]
			let nextIsBlank = nextLine.trimmingCharacters(in: .whitespaces).isEmpty
			result += currentIsBlank || nextIsBlank ? "\n" : "  \n"
		}

		return result
	}

	private static func containsBlockMarkdown(_ text: String) -> Bool {
		if text.contains("```") {
			return true
		}

		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty else { continue }

			if trimmed.hasPrefix("#")
				|| trimmed.hasPrefix("> ")
				|| trimmed.hasPrefix("- ")
				|| trimmed.hasPrefix("* ")
				|| trimmed.hasPrefix("+ ")
				|| trimmed.hasPrefix("|")
				|| trimmed == "---"
				|| trimmed == "***"
				|| trimmed == "___"
				|| trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
				return true
			}
		}

		return false
	}

	static func shouldCollapsePreview(for text: String, role: Message.Role) -> Bool {
		switch role {
		case .user, .assistant:
			return false
		default:
			let lineCount = text.components(separatedBy: .newlines).count
			return lineCount > maxPreviewLines || text.count > maxPreviewCharacters
		}
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

#Preview {
	ScrollView {
		VStack(alignment: .leading, spacing: 24) {
			MessageMarkdownView(
				text: (1...16).map { "assistant line \($0)" }.joined(separator: "\n"),
				role: .assistant,
				title: "Assistant"
			)

			MessageMarkdownView(
				text: (1...16).map { "tool output line \($0)" }.joined(separator: "\n"),
				role: .toolResult,
				title: "Tool Result"
			)
		}
		.padding()
	}
}
