import SwiftUI
import UIKit

// MARK: - AssistantMessageView

struct AssistantMessageView: View {
	let messageInfo: MessageInfo
	let sessionID: String
	let serverURL: String?

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
				HStack {
					Text(verbatim: block.toolCallName ?? "unknown tool")
						.font(.caption)
						.fontDesign(.monospaced)
					Spacer()
					Image(systemName: "terminal.fill")
				}
				.foregroundStyle(.teal)
				.padding(.vertical, 4)
				.padding(.horizontal, 8)
				.background(.teal.opacity(0.1))

				if let text = block.text, !text.isEmpty {
					ToolCallDetailsView(text: text)
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

		guard let serverURL else { return nil }

		do {
			let client = try PimuxServerClient(baseURL: serverURL)
			return client.attachmentURL(sessionID: sessionID, attachmentID: attachmentID)
		} catch {
			return nil
		}
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

	private var maxHeight: CGFloat {
		UIFont.preferredFont(forTextStyle: .callout).lineHeight * CGFloat(Self.maxVisibleLines)
	}

	private var route: MessageContextRoute {
		MessageContextRoute(title: "Thinking", text: text, role: .assistant)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			MessageMarkdownView(text: text, role: .assistant, title: "Thinking")
				.opacity(0.7)
				.frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .bottomLeading)
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
	let text: String

	var body: some View {
		Text(verbatim: text)
			.frame(maxWidth: .infinity, alignment: .leading)
			.font(.system(.caption, design: .monospaced))
			.foregroundStyle(.secondary)
			.textSelection(.enabled)
			.padding(.vertical, 8)
			.padding(.horizontal, 10)
			.background(.teal.opacity(0.08))
	}
}

#Preview {
	let sessionID = "preview"
	let attachmentID = "preview-img"
	let _ = PreviewAttachmentFixture.installImageAttachment(sessionID: sessionID, attachmentID: attachmentID)

	NavigationStack {
		AssistantMessageView(
			messageInfo: MessageInfo(
				message: Message(piSessionID: 1, role: .assistant, toolName: nil, position: 0, createdAt: Date()),
				contentBlocks: [
					MessageContentBlock(messageID: 1, type: "thinking", text: "Let me think about this step by step…\nFirst I need to check the file.\nThen I'll make the edit.", toolCallName: nil, position: 0),
					MessageContentBlock(messageID: 1, type: "toolCall", text: "src/main.swift (offset=10, limit=50)", toolCallName: "read", position: 1),
					MessageContentBlock(messageID: 1, type: "text", text: "Here's what I found in the file.", toolCallName: nil, position: 2),
					MessageContentBlock(messageID: 1, type: "image", text: nil, toolCallName: nil, mimeType: "image/png", attachmentID: attachmentID, position: 3),
				]
			),
			sessionID: sessionID,
			serverURL: nil
		)
		.padding()
	}
}
