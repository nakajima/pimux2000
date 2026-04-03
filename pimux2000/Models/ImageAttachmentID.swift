import Foundation

/// Mirrors the FNV-1a attachment ID algorithm from `pimux-server/src/message.rs`
/// so the iOS app can predict server-assigned attachment IDs for optimistic UI.
enum ImageAttachmentID {
	static func predict(mimeType: String, base64Data: String) -> String {
		let fnvOffset: UInt64 = 0xCBF2_9CE4_8422_2325
		let fnvPrime: UInt64 = 0x0000_0100_0000_01B3

		var hash = fnvOffset
		for byte in mimeType.utf8 {
			hash ^= UInt64(byte)
			hash &*= fnvPrime
		}
		hash ^= 0xFF
		hash &*= fnvPrime
		for byte in base64Data.utf8 {
			hash ^= UInt64(byte)
			hash &*= fnvPrime
		}

		return String(format: "img-%016llx", hash)
	}
}
