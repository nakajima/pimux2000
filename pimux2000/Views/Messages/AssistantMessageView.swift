import SwiftUI
import UIKit

// MARK: - AssistantMessageView

struct AssistantMessageView: View {
	@Environment(\.pimuxServerClient) private var pimuxServerClient

	let messageInfo: MessageInfo
	let sessionID: String

	private var message: Message { messageInfo.message }

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "sparkles")
				.foregroundStyle(.purple)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "sparkles", label: "Assistant", color: .purple)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					contentView(for: block)
				}
			}
		}
	}

	@ViewBuilder
	private func contentView(for block: MessageContentBlock) -> some View {
		switch block.type {
		case "text":
			if let text = block.text, !text.isEmpty {
				MessageMarkdownView(text: text, role: .assistant, title: "Assistant")
			}

		case "thinking":
			if let text = block.text, !text.isEmpty {
				ThinkingBlockView(text: text)
			}

		case "toolCall":
			VStack(alignment: .leading, spacing: 0) {
				HStack(alignment: .firstTextBaseline) {
					VStack(alignment: .leading, spacing: 2) {
						Text(verbatim: block.toolCallName ?? "unknown tool")
							.font(.caption)
							.fontDesign(.monospaced)
						if let toolCallID = block.toolCallID, !toolCallID.isEmpty {
							Text(verbatim: shortToolCallLabel(toolCallID))
								.font(.caption2)
								.foregroundStyle(.secondary)
						}
					}
					Spacer()
					Image(systemName: "terminal.fill")
				}
				.foregroundStyle(.teal)
				.padding(.vertical, 4)
				.padding(.horizontal, 8)
				.background(.teal.opacity(0.1))

				if let text = block.text, !text.isEmpty {
					ToolCallDetailsView(toolName: block.toolCallName, text: text)
				}
			}

		case "image":
			if let url = attachmentURL(for: block) {
				TranscriptImageView(
					url: url,
					sessionID: sessionID,
					mimeType: block.mimeType,
					attachmentID: block.attachmentID
				)
			} else {
				Label("Image", systemImage: "photo")
					.font(chatFont(style: .callout))
					.foregroundStyle(.secondary)
			}

		default:
			if let text = block.text, !text.isEmpty {
				Text(verbatim: text)
					.font(chatFont(style: .body))
					.foregroundStyle(.secondary)
			}
		}
	}

	private func attachmentURL(for block: MessageContentBlock) -> URL? {
		guard block.type == "image",
		      let attachmentID = block.attachmentID,
		      !attachmentID.isEmpty
		else {
			return nil
		}

		if let cachedURL = AttachmentStore.existingFileURL(
			sessionID: sessionID,
			attachmentID: attachmentID,
			mimeType: block.mimeType
		) {
			return cachedURL
		}

		guard let pimuxServerClient else { return nil }
		return pimuxServerClient.attachmentURL(sessionID: sessionID, attachmentID: attachmentID)
	}
}

// MARK: - ThinkingBlockView

struct ThinkingBlockView: View {
	private static let maxVisibleLines = 10

	let text: String

	private var needsTruncation: Bool {
		let lines = text.components(separatedBy: .newlines)
		return lines.count > Self.maxVisibleLines || text.count > Self.maxVisibleLines * 60
	}

	private var displayText: String {
		guard needsTruncation else { return text }
		let lines = text.components(separatedBy: .newlines)
		return lines.suffix(Self.maxVisibleLines).joined(separator: "\n")
	}

	private var maxHeight: CGFloat {
		UIFont.preferredFont(forTextStyle: .callout).lineHeight * CGFloat(Self.maxVisibleLines)
	}

	private var route: MessageContextRoute {
		MessageContextRoute(title: "Thinking", text: text, role: .assistant)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			MessageMarkdownView(text: displayText, role: .assistant, title: "Thinking")
				.opacity(0.7)
				.frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
				.clipped()
				.mask {
					VStack(spacing: 0) {
						if needsTruncation {
							LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
								.frame(height: maxHeight * 0.12)
						}
						Color.black
					}
				}
				.environment(\.markdownTextStyle, .caption)

			if needsTruncation {
				NavigationLink(value: Route.messageContext(route)) {
					Label("View full thinking", systemImage: "arrow.right.circle")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.tint)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.bottom, 8)
		.padding(.horizontal, 10)
		.background(.secondary.opacity(0.08))
	}
}

// MARK: - ToolCallDetailsView

struct ToolCallDetailsView: View {
	private static let maxVisibleLines = 10

	let toolName: String?
	let text: String

	private var needsTruncation: Bool {
		let lines = text.components(separatedBy: .newlines)
		return lines.count > Self.maxVisibleLines || text.count > Self.maxVisibleLines * 60
	}

	private var displayText: String {
		guard needsTruncation else { return text }
		let lines = text.components(separatedBy: .newlines)
		return lines.prefix(Self.maxVisibleLines).joined(separator: "\n")
	}

	private var maxHeight: CGFloat {
		UIFont.preferredFont(forTextStyle: .caption1).lineHeight * CGFloat(Self.maxVisibleLines)
	}

	private var routeTitle: String {
		let trimmedName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let trimmedName, !trimmedName.isEmpty else { return "Tool Call" }
		return "Tool Call · \(trimmedName)"
	}

	private var route: MessageContextRoute {
		MessageContextRoute(title: routeTitle, text: text, role: .toolResult)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(verbatim: displayText)
				.frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
				.font(.system(.caption, design: .monospaced))
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
				.clipped()
				.overlay(alignment: .bottom) {
					if needsTruncation {
						Rectangle()
							.fill(.teal.opacity(0.08))
							.frame(height: UIFont.preferredFont(forTextStyle: .caption1).lineHeight * 2)
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

			if needsTruncation {
				NavigationLink(value: Route.messageContext(route)) {
					Label("View full tool call", systemImage: "arrow.right.circle")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.tint)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.vertical, 8)
		.padding(.horizontal, 10)
		.background(.teal.opacity(0.08))
	}
}

#Preview {
	let sessionID = "preview"
	let attachmentID = "preview-img"
	_ = PreviewAttachmentFixture.installImageAttachment(sessionID: sessionID, attachmentID: attachmentID)

	return NavigationStack {
		AssistantMessageView(
			messageInfo: MessageInfo(
				message: Message(piSessionID: 1, role: .assistant, toolName: nil, position: 0, createdAt: Date()),
				contentBlocks: [
					MessageContentBlock(messageID: 1, type: "thinking", text: "Let me think about this step by step…\nFirst I need to check the file.\nThen I'll make the edit.", toolCallName: nil, position: 0),
					MessageContentBlock(
						messageID: 1,
						type: "toolCall",
						text: "{\n  \"path\": \"src/main.swift\",\n  \"offset\": 10,\n  \"limit\": 50,\n  \"includeHidden\": false,\n  \"showContext\": true,\n  \"surroundingLines\": 6,\n  \"annotations\": [\n    \"capture the import list\",\n    \"show the view body\",\n    \"include the preview block\",\n    \"keep enough lines for the next edit\"\n  ]\n}",
						toolCallName: "read",
						position: 1
					),
					MessageContentBlock(messageID: 1, type: "text", text: "Here's what I found in the file.", toolCallName: nil, position: 2),
					MessageContentBlock(messageID: 1, type: "image", text: nil, toolCallName: nil, mimeType: "image/png", attachmentID: attachmentID, position: 3),
				]
			),
			sessionID: sessionID
		)
		.padding()
	}
}
