#if DEBUG
import Foundation

enum PreviewAttachmentFixture {
	@discardableResult
	static func installImageAttachment(sessionID: String, attachmentID: String, mimeType: String = "image/png") -> URL? {
		guard let sourceURL else { return nil }
		guard let data = try? Data(contentsOf: sourceURL) else { return nil }
		return try? AttachmentStore.store(data: data, sessionID: sessionID, attachmentID: attachmentID, mimeType: mimeType)
	}

	private static var sourceURL: URL? {
		let fileURL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("Preview Content", isDirectory: true)
			.appendingPathComponent("preview-image.png")
		return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
	}
}
#endif
