import Foundation

struct PendingImagePreview: Identifiable, Equatable, Sendable {
	let id: UUID
	let previewData: Data
}

struct PendingLocalMessage: Identifiable, Equatable {
	let id: UUID
	let body: String
	let normalizedBody: String
	let imageAttachmentIDs: [String]
	let previewImages: [PendingImagePreview]
	let confirmedUserMessageBaseline: Int

	init(id: UUID = UUID(), body: String, images: [ComposerImage] = [], confirmedUserMessageBaseline: Int) {
		self.id = id
		self.body = body
		self.normalizedBody = normalizedPendingMessageBody(body)
		self.imageAttachmentIDs = images.compactMap(\.predictedAttachmentID)
		self.previewImages = images.compactMap { image in
			guard let previewData = image.previewData else { return nil }
			return PendingImagePreview(id: image.id, previewData: previewData)
		}
		self.confirmedUserMessageBaseline = confirmedUserMessageBaseline
	}

	fileprivate var signature: PendingMessageSignature {
		PendingMessageSignature(normalizedBody: normalizedBody, imageAttachmentIDs: imageAttachmentIDs)
	}
}

func pendingMessagesAwaitingConfirmation(
	_ pendingMessages: [PendingLocalMessage],
	confirmedMessages: [PimuxTranscriptMessage]
) -> [PendingLocalMessage] {
	let confirmedSignatures = confirmedMessages
		.filter { Message.Role($0.role) == .user }
		.map { confirmedMessageSignature($0) }

	var nextConfirmedSearchStart = 0
	var remainingPendingMessages: [PendingLocalMessage] = []

	for pendingMessage in pendingMessages {
		let searchStart = max(nextConfirmedSearchStart, pendingMessage.confirmedUserMessageBaseline)
		guard searchStart < confirmedSignatures.count else {
			remainingPendingMessages.append(pendingMessage)
			continue
		}

		if let matchIndex = confirmedSignatures[searchStart...].firstIndex(of: pendingMessage.signature) {
			nextConfirmedSearchStart = matchIndex + 1
		} else {
			remainingPendingMessages.append(pendingMessage)
		}
	}

	return remainingPendingMessages
}

func normalizedPendingMessageBody(_ text: String) -> String {
	text
		.replacingOccurrences(of: "\r\n", with: "\n")
		.replacingOccurrences(of: "\r", with: "\n")
		.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
}

// MARK: - Signature matching

private struct PendingMessageSignature: Equatable {
	let normalizedBody: String
	let imageAttachmentIDs: [String]
}

private func confirmedMessageSignature(_ message: PimuxTranscriptMessage) -> PendingMessageSignature {
	let imageIDs = message.blocks
		.filter { $0.type == "image" }
		.compactMap(\.attachmentId)

	if !imageIDs.isEmpty {
		// When image blocks are present, extract text from text blocks
		// rather than body, which may be a placeholder like "[Image]".
		let textParts = message.blocks
			.filter { $0.type == "text" }
			.compactMap(\.text)
		let body = normalizedPendingMessageBody(textParts.joined(separator: "\n"))
		return PendingMessageSignature(normalizedBody: body, imageAttachmentIDs: imageIDs)
	}

	return PendingMessageSignature(
		normalizedBody: normalizedPendingMessageBody(message.body),
		imageAttachmentIDs: []
	)
}
