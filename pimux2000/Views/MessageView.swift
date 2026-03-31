import QuickLook
import SwiftUI
import UIKit

// MARK: - PendingLocalMessageView

struct PendingLocalMessageView: View {
	let message: PendingLocalMessage

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "clock.fill")
				Text("You")
					.font(.caption)
					.fontWeight(.semibold)
					.textCase(.uppercase)
				Text("· Pending")
					.font(.caption)
			}
			.foregroundStyle(.secondary)

			if !message.previewImages.isEmpty {
				PendingImageStrip(images: message.previewImages)
					.opacity(0.55)
			}

			if !message.body.isEmpty {
				MessageMarkdownView(text: message.body, role: .user, title: "You")
					.opacity(0.55)
			}
		}
	}
}

private struct PendingImageStrip: View {
	let images: [PendingImagePreview]

	var body: some View {
		HStack(spacing: 6) {
			ForEach(images) { preview in
				if let uiImage = UIImage(data: preview.previewData) {
					Image(uiImage: uiImage)
						.resizable()
						.scaledToFill()
						.frame(width: 60, height: 60)
						.clipShape(RoundedRectangle(cornerRadius: 8))
				}
			}
		}
	}
}

// MARK: - MessageView

struct MessageView: View {
	let messageInfo: MessageInfo
	let sessionID: String
	let serverURL: String?

	private var message: Message { messageInfo.message }

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: roleIcon)
				.foregroundStyle(roleColor)
			VStack(alignment: .leading, spacing: 6) {
				HStack(spacing: 6) {

					Text(verbatim: roleLabel)
						.font(.caption)
						.fontWeight(.semibold)
						.textCase(.uppercase)

					if let toolName = message.toolName {
						Text(verbatim: "· \(toolName)")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.foregroundStyle(roleColor)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					ContentBlockView(
						block: block,
						messageRole: message.role,
						messageTitle: messageTitle,
						attachmentURL: attachmentURL(for: block)
					)
				}
			}
		}
	}

	private var roleLabel: String {
		switch message.role {
		case .user: "You"
		case .assistant: "Assistant"
		case .toolResult: "Tool Result"
		case .bashExecution: "Bash"
		case .custom: "Custom"
		case .branchSummary: "Branch Summary"
		case .compactionSummary: "Summary"
		case .other(let value): value
		}
	}

	private var roleIcon: String {
		switch message.role {
		case .user: "person.fill"
		case .assistant: "sparkles"
		case .toolResult: "wrench.fill"
		case .bashExecution: "terminal.fill"
		case .custom: "square.stack.3d.up.fill"
		case .branchSummary: "arrow.triangle.branch"
		case .compactionSummary: "archivebox.fill"
		case .other: "ellipsis.circle"
		}
	}

	private var roleColor: Color {
		switch message.role {
		case .user: .blue
		case .assistant: .purple
		case .toolResult: .orange
		case .bashExecution: .teal
		case .custom: .indigo
		case .branchSummary: .green
		case .compactionSummary: .brown
		case .other: .secondary
		}
	}

	private var messageTitle: String {
		if let toolName = message.toolName {
			return "\(roleLabel) · \(toolName)"
		}
		return roleLabel
	}

	private func attachmentURL(for block: MessageContentBlock) -> URL? {
		guard block.type == "image",
			let attachmentID = block.attachmentID,
			!attachmentID.isEmpty,
			let serverURL
		else {
			return nil
		}

		do {
			let client = try PimuxServerClient(baseURL: serverURL)
			return client.attachmentURL(sessionID: sessionID, attachmentID: attachmentID)
		} catch {
			return nil
		}
	}
}

// MARK: - ContentBlockView

struct ContentBlockView: View {
	let block: MessageContentBlock
	let messageRole: Message.Role
	let messageTitle: String
	let attachmentURL: URL?

	var body: some View {
		switch block.type {
		case "text":
			if let text = block.text, !text.isEmpty {
				MessageMarkdownView(text: text, role: messageRole, title: messageTitle)
			}

		case "thinking":
			if let text = block.text, !text.isEmpty {
				ThinkingBlockView(text: text)
			}

		case "toolCall":
			VStack(alignment: .leading, spacing: 8) {
				Label {
					Text(verbatim: block.toolCallName ?? "unknown tool")
				} icon: {
					Image(systemName: "terminal.fill")
				}
					.font(chatFont(style: .callout))
					.foregroundStyle(.teal)
					.padding(.vertical, 4)
					.padding(.horizontal, 8)
					.background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

				if let text = block.text, !text.isEmpty {
					ToolCallDetailsView(text: text)
				}
			}

		case "image":
			if let attachmentURL {
				TranscriptImageView(
					url: attachmentURL,
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
}

private struct ToolCallDetailsView: View {
	let text: String

	var body: some View {
		Text(verbatim: text)
			.font(.system(.caption, design: .monospaced))
			.foregroundStyle(.secondary)
			.textSelection(.enabled)
			.padding(.vertical, 8)
			.padding(.horizontal, 10)
			.background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
	}
}

private struct ThinkingBlockView: View {
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
			Text(verbatim: text)
				.font(chatFont(style: .callout))
				.italic()
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .bottomLeading)
				.clipped()

			if needsTruncation {
				NavigationLink(value: Route.messageContext(route)) {
					Label("View full thinking", systemImage: "arrow.right.circle")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.tint)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.vertical, 8)
		.padding(.horizontal, 10)
		.background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
	}
}

private struct TranscriptImageView: View {
	let url: URL
	let mimeType: String?
	let attachmentID: String?

	@State private var quickLookURL: URL?
	@State private var isPreviewLoading = false

	var body: some View {
		AsyncImage(url: url) { phase in
			switch phase {
			case .empty:
				placeholder(label: "Loading image…", systemImage: "photo")
			case .success(let image):
				image
					.resizable()
					.scaledToFit()
					.frame(maxWidth: 320, maxHeight: 240, alignment: .leading)
					.clipShape(RoundedRectangle(cornerRadius: 10))
					.overlay(alignment: .center) {
						if isPreviewLoading {
							ProgressView()
								.padding(8)
								.background(.thinMaterial, in: Circle())
						}
					}
					.onTapGesture {
						Task { await openQuickLook() }
					}
			case .failure:
				placeholder(label: "Couldn't load image", systemImage: "exclamationmark.triangle")
			@unknown default:
				placeholder(label: "Image", systemImage: "photo")
			}
		}
		.quickLookPreview($quickLookURL)
		.onDisappear { cleanupTempFile() }
	}

	private func openQuickLook() async {
		guard !isPreviewLoading else { return }
		isPreviewLoading = true
		defer { isPreviewLoading = false }

		do {
			let (data, _) = try await URLSession.shared.data(from: url)
			cleanupTempFile()
			let ext = fileExtension(for: mimeType)
			let tempURL = FileManager.default.temporaryDirectory
				.appendingPathComponent("pimux-preview-\(UUID().uuidString)")
				.appendingPathExtension(ext)
			try data.write(to: tempURL)
			quickLookURL = tempURL
		} catch {
			print("Failed to download image for QuickLook preview: \(error)")
		}
	}

	private func cleanupTempFile() {
		if let url = quickLookURL {
			try? FileManager.default.removeItem(at: url)
			quickLookURL = nil
		}
	}

	private func fileExtension(for mimeType: String?) -> String {
		switch mimeType {
		case "image/png": "png"
		case "image/jpeg": "jpg"
		case "image/gif": "gif"
		case "image/webp": "webp"
		case "image/heic": "heic"
		default: "png"
		}
	}

	@ViewBuilder
	private func placeholder(label: String, systemImage: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Label(label, systemImage: systemImage)
				.font(chatFont(style: .callout))
				.foregroundStyle(.secondary)

			if let mimeType, !mimeType.isEmpty {
				Text(verbatim: mimeType)
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			if let attachmentID, !attachmentID.isEmpty {
				Text(verbatim: attachmentID)
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
		.padding(.vertical, 8)
		.padding(.horizontal, 10)
		.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
	}
}

// MARK: - Previews

#Preview("Message roles") {
	ScrollView {
		VStack(alignment: .leading, spacing: 16) {
			MessageView(
				messageInfo: MessageInfo(
					message: Message(piSessionID: 1, role: .user, toolName: nil, position: 0, createdAt: Date()),
					contentBlocks: [
						MessageContentBlock(messageID: 1, type: "text", text: "Hello, can you help me?", toolCallName: nil, position: 0)
					]
				),
				sessionID: "preview",
				serverURL: nil
			)
			MessageView(
				messageInfo: MessageInfo(
					message: Message(piSessionID: 1, role: .assistant, toolName: nil, position: 1, createdAt: Date()),
					contentBlocks: [
						MessageContentBlock(messageID: 2, type: "text", text: "Of course! What do you need help with?", toolCallName: nil, position: 0)
					]
				),
				sessionID: "preview",
				serverURL: nil
			)
			MessageView(
				messageInfo: MessageInfo(
					message: Message(piSessionID: 1, role: .toolResult, toolName: "read", position: 2, createdAt: Date()),
					contentBlocks: [
						MessageContentBlock(messageID: 3, type: "text", text: "File contents returned successfully.", toolCallName: nil, position: 0)
					]
				),
				sessionID: "preview",
				serverURL: nil
			)
			MessageView(
				messageInfo: MessageInfo(
					message: Message(piSessionID: 1, role: .bashExecution, toolName: nil, position: 3, createdAt: Date()),
					contentBlocks: [
						MessageContentBlock(messageID: 4, type: "text", text: "$ echo hello\nhello", toolCallName: nil, position: 0)
					]
				),
				sessionID: "preview",
				serverURL: nil
			)
		}
		.padding()
	}
}

#Preview("Content blocks") {
	ScrollView {
		VStack(alignment: .leading, spacing: 16) {
			ContentBlockView(
				block: MessageContentBlock(messageID: 1, type: "text", text: "A plain text block.", toolCallName: nil, position: 0),
				messageRole: .assistant,
				messageTitle: "Assistant",
				attachmentURL: nil
			)
			ContentBlockView(
				block: MessageContentBlock(messageID: 1, type: "thinking", text: "Let me think about this step by step…\nFirst I need to check the file.\nThen I'll make the edit.", toolCallName: nil, position: 1),
				messageRole: .assistant,
				messageTitle: "Assistant",
				attachmentURL: nil
			)
			ContentBlockView(
				block: MessageContentBlock(messageID: 1, type: "toolCall", text: "src/main.swift (offset=10, limit=50)", toolCallName: "read", position: 2),
				messageRole: .assistant,
				messageTitle: "Assistant",
				attachmentURL: nil
			)
			ContentBlockView(
				block: MessageContentBlock(messageID: 1, type: "image", text: nil, toolCallName: nil, position: 3),
				messageRole: .assistant,
				messageTitle: "Assistant",
				attachmentURL: nil
			)
		}
		.padding()
	}
}

#Preview("Pending message") {
	VStack(alignment: .leading, spacing: 16) {
		PendingLocalMessageView(
			message: PendingLocalMessage(
				body: "This message hasn't been confirmed yet.",
				images: [],
				confirmedUserMessageBaseline: 0
			)
		)
	}
	.padding()
}
