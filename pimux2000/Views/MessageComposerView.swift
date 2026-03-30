import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MessageComposerView: View {
	@Binding var text: String
	var attachments: [ComposerImage] = []
	var customCommands: [PimuxSessionCommand] = []
	var canAttachImages: Bool = true
	var placeholder: String = "Send a message"
	var isEnabled: Bool = true
	var isSending: Bool = false
	var isAgentActive: Bool = false
	var errorMessage: String? = nil
	var onSend: () -> Void
	var onStop: () -> Void = {}
	var onRemoveAttachment: (UUID) -> Void = { _ in }
	var onPhotosSelected: ([PhotosPickerItem]) -> Void = { _ in }
	var onImportImageData: (Data, ComposerImage.Source) -> Void = { _, _ in }

	@State private var selectedPhotoItems: [PhotosPickerItem] = []
	@State private var showPhotoPicker = false
	@State private var isCameraPresented = false
	@State private var isDropTargeted = false
	@State private var slashMenuSelection: Int = 0

	private var trimmedText: String {
		text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private var hasReadyAttachments: Bool {
		attachments.contains(where: \.isReady)
	}

	private var hasLoadingAttachments: Bool {
		attachments.contains { if case .loading = $0.processingState { return true }; return false }
	}

	private var canSend: Bool {
		isEnabled && !isSending && !hasLoadingAttachments && (!trimmedText.isEmpty || hasReadyAttachments)
	}

	private var matchingCommands: [SlashCommand] {
		// Only match when the text is purely a slash prefix (no spaces yet)
		let trimmed = trimmedText
		guard trimmed.hasPrefix("/"), !trimmed.dropFirst().contains(" ") else { return [] }
		let allCommands = SlashCommand.merged(custom: customCommands)
		return SlashCommand.matching(query: trimmed, from: allCommands)
	}

	var body: some View {
		VStack(spacing: 0) {
			Divider()

			VStack(alignment: .leading, spacing: 8) {
				if !matchingCommands.isEmpty {
					SlashCommandMenuView(commands: matchingCommands, selectedIndex: slashMenuSelection) { command in
						text = command.displayName + " "
					}
					.transition(.move(edge: .bottom).combined(with: .opacity))
				}

				if let errorMessage, !errorMessage.isEmpty {
					Label {
						Text(verbatim: errorMessage)
					} icon: {
						Image(systemName: "exclamationmark.triangle.fill")
					}
						.font(.caption)
						.foregroundStyle(.red)
				}

				if !attachments.isEmpty {
					ComposerAttachmentStrip(attachments: attachments, onRemove: onRemoveAttachment)
				}

				HStack(alignment: .bottom, spacing: 8) {
					Menu {
						Button { showPhotoPicker = true } label: {
							Label("Photo Library", systemImage: "photo.on.rectangle")
						}

						Button(action: pasteFromClipboard) {
							Label("Paste", systemImage: "doc.on.clipboard")
						}

						if UIImagePickerController.isSourceTypeAvailable(.camera) {
							Button { isCameraPresented = true } label: {
								Label("Take Photo", systemImage: "camera")
							}
						}
					} label: {
						Image(systemName: "plus.circle.fill")
							.font(.system(size: 24))
							.foregroundStyle(.tint)
							.frame(width: 36, height: 36)
							.contentShape(Rectangle())
					}
					.disabled(!isEnabled || isSending || !canAttachImages || attachments.count >= 8)

					TextField(placeholder, text: $text, axis: .vertical)
						.lineLimit(1 ... 6)
						#if os(iOS)
						.textInputAutocapitalization(.sentences)
						#endif
						.padding(.horizontal, 12)
						.padding(.vertical, 10)
						.background(.background, in: RoundedRectangle(cornerRadius: 12))
						.disabled(!isEnabled || isSending)

					if isAgentActive && !isSending {
						Button(action: onStop) {
							Image(systemName: "stop.circle.fill")
								.font(.system(size: 28))
								.foregroundStyle(.red)
						}
						.buttonStyle(.plain)
						.keyboardShortcut(.escape, modifiers: [])
						.accessibilityLabel("Stop agent")
					} else {
						Button(action: onSend) {
							if isSending {
								ProgressView()
									.controlSize(.small)
									.frame(width: 28, height: 28)
							} else {
								Image(systemName: "arrow.up.circle.fill")
									.font(.system(size: 28))
							}
						}
						.buttonStyle(.plain)
						.keyboardShortcut(.return, modifiers: [.command])
						.disabled(!canSend)
						.accessibilityLabel("Send message")
					}
				}
			}
			.padding(.horizontal)
			.padding(.vertical, 12)
			.background(.thinMaterial)
			.animation(.easeOut(duration: 0.15), value: matchingCommands.map(\.name))
			.animation(.easeOut(duration: 0.15), value: attachments.map(\.id))
			.onChange(of: matchingCommands.map(\.name)) {
				slashMenuSelection = 0
			}
			.onKeyPress(phases: [.down, .repeat]) { press in
				if matchingCommands.isEmpty {
					if press.key == .escape && isAgentActive && !isSending {
						onStop()
						return .handled
					}
					return .ignored
				}

				let isDown = press.key == .downArrow
					|| (press.key == KeyEquivalent("n") && press.modifiers.contains(.control))
				let isUp = press.key == .upArrow
					|| (press.key == KeyEquivalent("p") && press.modifiers.contains(.control))

				if isDown {
					slashMenuSelection = min(slashMenuSelection + 1, matchingCommands.count - 1)
					return .handled
				}
				if isUp {
					slashMenuSelection = max(slashMenuSelection - 1, 0)
					return .handled
				}
				if press.key == .escape {
					text = ""
					return .handled
				}
				if press.key == .return {
					let command = matchingCommands[slashMenuSelection]
					text = command.displayName + " "
					return .handled
				}

				return .ignored
			}
			.dropDestination(for: TransferableImage.self) { items, _ in
				for item in items {
					onImportImageData(item.data, .drop)
				}
				return !items.isEmpty
			} isTargeted: { targeted in
				isDropTargeted = targeted
			}
			.overlay {
				if isDropTargeted {
					RoundedRectangle(cornerRadius: 12)
						.stroke(.tint, lineWidth: 2)
						.allowsHitTesting(false)
				}
			}
		}
		.photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems, maxSelectionCount: max(1, 8 - attachments.count), matching: .images)
		.onChange(of: selectedPhotoItems) {
			guard !selectedPhotoItems.isEmpty else { return }
			onPhotosSelected(selectedPhotoItems)
			selectedPhotoItems = []
		}
		.sheet(isPresented: $isCameraPresented) {
			CameraCaptureView(
				onCapture: { image in
					isCameraPresented = false
					if let data = image.jpegData(compressionQuality: 1.0) {
						onImportImageData(data, .camera)
					}
				},
				onCancel: {
					isCameraPresented = false
				}
			)
		}
	}

	private func pasteFromClipboard() {
		let pasteboard = UIPasteboard.general
		let imageTypes = [
			UTType.png.identifier,
			UTType.jpeg.identifier,
			UTType.webP.identifier,
			UTType.heic.identifier,
		]

		for type in imageTypes {
			if let data = pasteboard.data(forPasteboardType: type) {
				onImportImageData(data, .paste)
				return
			}
		}

		if let image = pasteboard.image, let data = image.pngData() {
			onImportImageData(data, .paste)
		}
	}
}

// MARK: - Drop Support

private struct TransferableImage: Transferable {
	let data: Data

	static var transferRepresentation: some TransferRepresentation {
		DataRepresentation(importedContentType: .image) { data in
			TransferableImage(data: data)
		}
	}
}

// MARK: - Attachment Strip

private struct ComposerAttachmentStrip: View {
	let attachments: [ComposerImage]
	let onRemove: (UUID) -> Void

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(attachments) { attachment in
					ComposerAttachmentTile(attachment: attachment) {
						onRemove(attachment.id)
					}
				}
			}
		}
	}
}

private struct ComposerAttachmentTile: View {
	let attachment: ComposerImage
	let onRemove: () -> Void

	var body: some View {
		ZStack(alignment: .topTrailing) {
			Group {
				switch attachment.processingState {
				case .loading:
					RoundedRectangle(cornerRadius: 8)
						.fill(.quaternary)
						.overlay { ProgressView().controlSize(.small) }
				case .ready:
					if let previewData = attachment.previewData,
						let uiImage = UIImage(data: previewData)
					{
						Image(uiImage: uiImage)
							.resizable()
							.scaledToFill()
							.clipShape(RoundedRectangle(cornerRadius: 8))
					} else {
						RoundedRectangle(cornerRadius: 8)
							.fill(.quaternary)
							.overlay {
								Image(systemName: "photo")
									.foregroundStyle(.secondary)
							}
					}
				case .failed:
					RoundedRectangle(cornerRadius: 8)
						.fill(.red.opacity(0.15))
						.overlay {
							Image(systemName: "exclamationmark.triangle.fill")
								.font(.caption)
								.foregroundStyle(.red)
						}
				}
			}
			.frame(width: 60, height: 60)

			Button(action: onRemove) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 18))
					.foregroundStyle(.white, .black.opacity(0.6))
			}
			.buttonStyle(.plain)
			.offset(x: 6, y: -6)
		}
	}
}

// MARK: - Slash Command Menu

private struct SlashCommandMenuView: View {
	let commands: [SlashCommand]
	var selectedIndex: Int = 0
	let onSelect: (SlashCommand) -> Void

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
						Button {
							onSelect(command)
						} label: {
							HStack(spacing: 8) {
								Text(command.displayName)
									.fontWeight(.medium)
									.foregroundStyle(.primary)
								Text(command.description)
									.foregroundStyle(.secondary)
									.lineLimit(1)
								Spacer()
							}
							.font(.callout)
							.padding(.horizontal, 12)
							.padding(.vertical, 8)
							.background(
								index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear,
								in: RoundedRectangle(cornerRadius: 6)
							)
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
						.id(command.id)
					}
				}
			}
			.frame(maxHeight: 200)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
			.onChange(of: selectedIndex) {
				guard selectedIndex < commands.count else { return }
				withAnimation {
					proxy.scrollTo(commands[selectedIndex].id, anchor: .center)
				}
			}
		}
	}
}

// MARK: - Previews

private struct MessageComposerPreviewHost: View {
	@State var text: String
	var attachments: [ComposerImage] = []
	var isEnabled: Bool = true
	var isSending: Bool = false
	var errorMessage: String? = nil

	var body: some View {
		VStack(spacing: 0) {
			Spacer()

			MessageComposerView(
				text: $text,
				attachments: attachments,
				isEnabled: isEnabled,
				isSending: isSending,
				errorMessage: errorMessage,
				onSend: {}
			)
		}
		.background(.background)
	}
}

#Preview("Ready") {
	MessageComposerPreviewHost(text: "Continue from here")
}

#Preview("Slash commands") {
	MessageComposerPreviewHost(text: "/")
}

#Preview("Slash filter") {
	MessageComposerPreviewHost(text: "/co")
}

#Preview("Sending") {
	MessageComposerPreviewHost(text: "Continue from here", isSending: true)
}

#Preview("Error") {
	MessageComposerPreviewHost(
		text: "",
		isEnabled: true,
		errorMessage: "Timed out waiting for host confirmation."
	)
}

#Preview("With attachments") {
	MessageComposerPreviewHost(
		text: "Check this out",
		attachments: {
			var ready = ComposerImage(source: .library)
			ready.processingState = .ready

			let loading = ComposerImage(source: .library)

			var failed = ComposerImage(source: .library)
			failed.processingState = .failed("Too large")

			return [ready, loading, failed]
		}()
	)
}

#Preview("Image only") {
	MessageComposerPreviewHost(
		text: "",
		attachments: {
			var image = ComposerImage(source: .library)
			image.processingState = .ready
			return [image]
		}()
	)
}
