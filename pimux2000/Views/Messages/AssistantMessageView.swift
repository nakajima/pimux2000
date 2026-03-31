import QuickLook
import SwiftUI
import UIKit

// MARK: - Preview image override

private struct PreviewImageURLKey: EnvironmentKey {
	static let defaultValue: URL? = nil
}

extension EnvironmentValues {
	var previewImageURL: URL? {
		get { self[PreviewImageURLKey.self] }
		set { self[PreviewImageURLKey.self] = newValue }
	}
}

// MARK: - AssistantMessageView

struct AssistantMessageView: View {
	let messageInfo: MessageInfo
	let sessionID: String
	let serverURL: String?

	@Environment(\.previewImageURL) private var previewImageURL

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
			if let url = attachmentURL(for: block) ?? previewImageURL {
				TranscriptImageView(
					url: url,
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

// MARK: - ToolCallDetailsView

struct ToolCallDetailsView: View {
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

// MARK: - TranscriptImageView

struct TranscriptImageView: View {
	let url: URL
	let mimeType: String?
	let attachmentID: String?

	@Environment(\.previewImageURL) private var previewImageURL
	@State private var quickLookURL: URL?
	@State private var isPreviewLoading = false

	private var resolvedURL: URL { previewImageURL ?? url }

	var body: some View {
		Group {
			if resolvedURL.isFileURL, let uiImage = UIImage(contentsOfFile: resolvedURL.path) {
				imageContent(Image(uiImage: uiImage))
			} else {
				AsyncImage(url: resolvedURL) { phase in
					switch phase {
					case .empty:
						placeholder(label: "Loading image…", systemImage: "photo")
					case .success(let image):
						imageContent(image)
					case .failure:
						placeholder(label: "Couldn't load image", systemImage: "exclamationmark.triangle")
					@unknown default:
						placeholder(label: "Image", systemImage: "photo")
					}
				}
			}
		}
		.quickLookPreview($quickLookURL)
		.onDisappear { cleanupTempFile() }
	}

	private func imageContent(_ image: Image) -> some View {
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
	}

	private func openQuickLook() async {
		guard !isPreviewLoading else { return }
		isPreviewLoading = true
		defer { isPreviewLoading = false }

		do {
			let (data, _) = try await URLSession.shared.data(from: resolvedURL)
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

#Preview {
	NavigationStack {
		AssistantMessageView(
			messageInfo: MessageInfo(
				message: Message(piSessionID: 1, role: .assistant, toolName: nil, position: 0, createdAt: Date()),
				contentBlocks: [
					MessageContentBlock(messageID: 1, type: "thinking", text: "Let me think about this step by step…\nFirst I need to check the file.\nThen I'll make the edit.", toolCallName: nil, position: 0),
					MessageContentBlock(messageID: 1, type: "toolCall", text: "src/main.swift (offset=10, limit=50)", toolCallName: "read", position: 1),
					MessageContentBlock(messageID: 1, type: "text", text: "Here's what I found in the file.", toolCallName: nil, position: 2),
					MessageContentBlock(messageID: 1, type: "image", text: nil, toolCallName: nil, mimeType: "image/png", attachmentID: "preview-img", position: 3),
				]
			),
			sessionID: "preview",
			serverURL: nil
		)
		.padding()
	}
	.environment(\.previewImageURL, Bundle.main.url(forResource: "preview-image", withExtension: "png"))
}
