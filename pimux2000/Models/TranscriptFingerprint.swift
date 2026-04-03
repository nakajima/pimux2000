import Foundation

struct TranscriptFingerprint {
	private static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
	private static let prime: UInt64 = 0x100_0000_01B3

	private var state: UInt64 = Self.offsetBasis

	init() {}

	var value: UInt64 { state }

	mutating func combine(_ value: UInt8) {
		state ^= UInt64(value)
		state &*= Self.prime
	}

	mutating func combine(_ value: UInt64) {
		var remaining = value
		for _ in 0 ..< 8 {
			combine(UInt8(truncatingIfNeeded: remaining))
			remaining >>= 8
		}
	}

	mutating func combine(_ value: Int) {
		combine(UInt64(bitPattern: Int64(value)))
	}

	mutating func combine(_ value: Int64) {
		combine(UInt64(bitPattern: value))
	}

	mutating func combine(_ value: String) {
		combine(UInt64(value.utf8.count))
		for byte in value.utf8 {
			combine(byte)
		}
	}

	mutating func combine(_ value: String?) {
		guard let value else {
			combine(UInt8(0))
			return
		}

		combine(UInt8(1))
		combine(value)
	}

	static func make(_ build: (inout TranscriptFingerprint) -> Void) -> UInt64 {
		var fingerprint = TranscriptFingerprint()
		build(&fingerprint)
		return fingerprint.value
	}
}
