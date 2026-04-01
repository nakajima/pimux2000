import Foundation

enum AttachmentStore {
	private static let rootDirectoryName = "attachments"
	private static let allowedFileNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))

	static func existingFileURL(sessionID: String, attachmentID: String, mimeType: String?) -> URL? {
		let fileURL = fileURL(sessionID: sessionID, attachmentID: attachmentID, mimeType: mimeType)
		return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
	}

	@discardableResult
	static func store(data: Data, sessionID: String, attachmentID: String, mimeType: String?) throws -> URL {
		let fileURL = fileURL(sessionID: sessionID, attachmentID: attachmentID, mimeType: mimeType)
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true,
			attributes: nil
		)
		try data.write(to: fileURL, options: .atomic)
		return fileURL
	}

	static func removeAll() throws {
		let rootURL = rootDirectoryURL
		guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
		try FileManager.default.removeItem(at: rootURL)
	}

	static func fileExtension(for mimeType: String?) -> String {
		switch mimeType {
		case "image/png": "png"
		case "image/jpeg": "jpg"
		case "image/gif": "gif"
		case "image/webp": "webp"
		case "image/heic": "heic"
		default: "png"
		}
	}

	private static func fileURL(sessionID: String, attachmentID: String, mimeType: String?) -> URL {
		let sessionDirectory = rootDirectoryURL.appendingPathComponent(sanitizedFileName(sessionID), isDirectory: true)
		return sessionDirectory
			.appendingPathComponent(sanitizedFileName(attachmentID))
			.appendingPathExtension(fileExtension(for: mimeType))
	}

	private static var rootDirectoryURL: URL {
		let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL.documentsDirectory
		return baseURL.appendingPathComponent(rootDirectoryName, isDirectory: true)
	}

	private static func sanitizedFileName(_ value: String) -> String {
		let sanitized = String(value.unicodeScalars.map { scalar in
			allowedFileNameCharacters.contains(scalar) ? Character(scalar) : "_"
		})
		return sanitized.isEmpty ? "attachment" : sanitized
	}
}
