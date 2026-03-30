import Foundation

struct ComposerImage: Identifiable, Sendable {
	enum ProcessingState: Sendable, Equatable {
		case loading
		case ready
		case failed(String)
	}

	enum Source: Sendable, Equatable {
		case library
		case camera
		case paste
		case drop
	}

	let id: UUID
	let source: Source
	var processingState: ProcessingState
	var previewData: Data?
	var mimeType: String?
	var base64Data: String?
	var predictedAttachmentID: String?

	init(id: UUID = UUID(), source: Source) {
		self.id = id
		self.source = source
		self.processingState = .loading
	}

	var isReady: Bool {
		if case .ready = processingState { return true }
		return false
	}

	var inputImage: PimuxInputImage? {
		guard let mimeType, let base64Data, isReady else { return nil }
		return PimuxInputImage(mimeType: mimeType, data: base64Data)
	}
}
