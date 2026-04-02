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
	var loadArgumentCompletions: @Sendable (String, String) async -> [SlashCommandArgumentCompletion] = { _, _ in [] }
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
	@State private var slashMenuItems: [SlashCompletionMenuItem] = []
	@State private var slashCompletionTask: Task<Void, Never>?

	private var trimmedText: String {
		text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private var allCommands: [SlashCommand] {
		SlashCommand.merged(custom: customCommands)
	}

	private var hasReadyAttachments: Bool {
		attachments.contains(where: \.isReady)
	}

	private var hasLoadingAttachments: Bool {
		attachments.contains { if case .loading = $0.processingState { return true }; return false }
	}

	private var slashValidationMessage: String? {
		guard !hasReadyAttachments else { return nil }
		return SlashCommand.validationMessage(for: trimmedText, commands: allCommands)
	}

	private var canSend: Bool {
		isEnabled
			&& !isSending
			&& !hasLoadingAttachments
			&& (!trimmedText.isEmpty || hasReadyAttachments)
			&& slashValidationMessage == nil
	}

	var body: some View {
		VStack(spacing: 0) {
			Divider()

			VStack(alignment: .leading, spacing: 8) {
				if !slashMenuItems.isEmpty {
					SlashCommandMenuView(items: slashMenuItems, selectedIndex: slashMenuSelection) { item in
						applySlashCompletion(item)
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

				if let slashValidationMessage, !slashValidationMessage.isEmpty {
					Label {
						Text(verbatim: slashValidationMessage)
					} icon: {
						Image(systemName: "exclamationmark.circle.fill")
					}
						.font(.caption)
						.foregroundStyle(.orange)
				}

				if !attachments.isEmpty {
					ComposerAttachmentStrip(attachments: attachments, onRemove: onRemoveAttachment)
				}

				HStack(alignment: .center, spacing: 8) {
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
						.autocorrectionDisabled()
						#if os(iOS)
						.textInputAutocapitalization(.never)
						#endif
						.padding(.horizontal, 12)
						.padding(.vertical, 10)
						.background(.background, in: RoundedRectangle(cornerRadius: 12))
						.disabled(!isEnabled || isSending)
						.onSubmit(handleSubmit)

					if isAgentActive && !isSending {
						Button(action: onStop) {
							Image(systemName: "stop.circle.fill")
								.font(.system(size: 28))
						}
						.buttonStyle(.plain)
						.keyboardShortcut(.escape, modifiers: [])
						.accessibilityLabel("Stop agent")
					} else {
						Button(action: sendIfAllowed) {
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
			.animation(.easeOut(duration: 0.15), value: slashMenuItems.map(\.id))
			.animation(.easeOut(duration: 0.15), value: attachments.map(\.id))
			.onAppear(perform: refreshSlashMenuItems)
			.onDisappear {
				slashCompletionTask?.cancel()
				slashCompletionTask = nil
			}
			.onChange(of: text) {
				refreshSlashMenuItems()
			}
			.onChange(of: customCommands.map(\.id)) {
				refreshSlashMenuItems()
			}
			.onChange(of: slashMenuItems.map(\.id)) {
				slashMenuSelection = 0
			}
			.onKeyPress(phases: [.down, .repeat]) { press in
				let hasMenu = !slashMenuItems.isEmpty
				let isDown = press.key == .downArrow
					|| (press.key == KeyEquivalent("n") && press.modifiers.contains(.control))
				let isUp = press.key == .upArrow
					|| (press.key == KeyEquivalent("p") && press.modifiers.contains(.control))

				if hasMenu && isDown {
					slashMenuSelection = min(slashMenuSelection + 1, slashMenuItems.count - 1)
					return .handled
				}
				if hasMenu && isUp {
					slashMenuSelection = max(slashMenuSelection - 1, 0)
					return .handled
				}
				if press.key == .escape {
					if hasMenu || SlashCommand.draftContext(for: text) != nil {
						text = ""
						return .handled
					}
					if isAgentActive && !isSending {
						onStop()
						return .handled
					}
					return .ignored
				}
				if hasMenu && (press.key == .return || press.key == .tab) {
					acceptSelectedSlashCompletion()
					return .handled
				}
				if !hasMenu && press.key == .escape && isAgentActive && !isSending {
					onStop()
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

	private func handleSubmit() {
		if !slashMenuItems.isEmpty {
			acceptSelectedSlashCompletion()
			return
		}

		sendIfAllowed()
	}

	private func sendIfAllowed() {
		guard canSend else { return }
		onSend()
	}

	private func refreshSlashMenuItems() {
		slashCompletionTask?.cancel()
		slashCompletionTask = nil

		guard let context = SlashCommand.draftContext(for: text) else {
			slashMenuItems = []
			return
		}

		switch context.phase {
		case .commandName(let prefix):
			let query = "/\(prefix)"
			slashMenuItems = SlashCommand.matching(query: query, from: allCommands).map(SlashCompletionMenuItem.init)
		case .arguments(let commandName, let argumentText):
			guard let command = SlashCommand.command(named: commandName, from: allCommands) else {
				slashMenuItems = []
				return
			}

			let localItems = command.localArgumentCompletions(argumentPrefix: argumentText)
			if !localItems.isEmpty || command.source == "builtin" {
				slashMenuItems = localItems.map { SlashCompletionMenuItem(commandName: commandName, completion: $0) }
				return
			}

			guard command.source == "extension" else {
				slashMenuItems = []
				return
			}

			let expectedText = text
			slashMenuItems = []
			slashCompletionTask = Task {
				let completions = await loadArgumentCompletions(commandName, argumentText)
				guard !Task.isCancelled else { return }
				await MainActor.run {
					guard text == expectedText else { return }
					slashMenuItems = completions.map {
						SlashCompletionMenuItem(commandName: commandName, completion: $0)
					}
				}
			}
		}
	}

	private func acceptSelectedSlashCompletion() {
		guard slashMenuSelection >= 0, slashMenuSelection < slashMenuItems.count else { return }
		applySlashCompletion(slashMenuItems[slashMenuSelection])
	}

	private func applySlashCompletion(_ item: SlashCompletionMenuItem) {
		switch item.kind {
		case .command(let command):
			text = command.displayName + " "
		case .argument(let commandName, let completion):
			text = "/\(commandName) \(completion.value) "
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

private struct SlashCompletionMenuItem: Identifiable, Equatable {
	enum Kind: Equatable {
		case command(SlashCommand)
		case argument(commandName: String, completion: SlashCommandArgumentCompletion)
	}

	let kind: Kind
	let title: String
	let subtitle: String

	var id: String {
		switch kind {
		case .command(let command):
			return "command:\(command.id)"
		case .argument(let commandName, let completion):
			return "argument:\(commandName):\(completion.id)"
		}
	}

	init(_ command: SlashCommand) {
		kind = .command(command)
		title = command.displayName
		subtitle = command.description
	}

	init(commandName: String, completion: SlashCommandArgumentCompletion) {
		kind = .argument(commandName: commandName, completion: completion)
		title = completion.label
		subtitle = completion.description ?? ""
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
					if let previewData = attachment.previewData {
						InlineDataImageView(id: attachment.id.uuidString, data: previewData)
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
	let items: [SlashCompletionMenuItem]
	var selectedIndex: Int = 0
	let onSelect: (SlashCompletionMenuItem) -> Void

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
						Button {
							onSelect(item)
						} label: {
							HStack(spacing: 8) {
								Text(item.title)
									.fontWeight(.medium)
									.foregroundStyle(.primary)
								Text(item.subtitle)
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
						.id(item.id)
					}
				}
			}
			.frame(maxHeight: 200)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
			.onChange(of: selectedIndex) {
				guard selectedIndex < items.count else { return }
				withAnimation {
					proxy.scrollTo(items[selectedIndex].id, anchor: .center)
				}
			}
		}
	}
}

// MARK: - Previews

private struct MessageComposerPreviewHost: View {
	@State var text: String
	var attachments: [ComposerImage] = []
	var customCommands: [PimuxSessionCommand] = []
	var isEnabled: Bool = true
	var isSending: Bool = false
	var errorMessage: String? = nil
	var loadArgumentCompletions: @Sendable (String, String) async -> [SlashCommandArgumentCompletion] = { _, _ in [] }

	var body: some View {
		VStack(spacing: 0) {
			Spacer()

			MessageComposerView(
				text: $text,
				attachments: attachments,
				customCommands: customCommands,
				isEnabled: isEnabled,
				isSending: isSending,
				errorMessage: errorMessage,
				loadArgumentCompletions: loadArgumentCompletions,
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

#Preview("Slash argument completions") {
	MessageComposerPreviewHost(
		text: "/pirot ",
		customCommands: [
			PimuxSessionCommand(name: "pirot", description: "Pirot repo commands", source: "extension")
		],
		loadArgumentCompletions: { commandName, _ in
			guard commandName == "pirot" else { return [] }
			return [
				SlashCommandArgumentCompletion(value: "sync", label: "sync", description: "Sync pirot resources"),
				SlashCommandArgumentCompletion(value: "restart-server", label: "restart-server", description: "Restart the pirot server"),
			]
		}
	)
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
