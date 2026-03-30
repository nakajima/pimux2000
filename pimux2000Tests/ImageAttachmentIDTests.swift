import Foundation
@testable import pimux2000
import Testing

struct ImageAttachmentIDTests {
	@Test
	func matchesServerGoldenValues() {
		#expect(
			ImageAttachmentID.predict(mimeType: "image/png", base64Data: "ZmFrZQ==")
				== "img-5af988d42aba5be1"
		)
		#expect(
			ImageAttachmentID.predict(mimeType: "image/jpeg", base64Data: "ZmFrZQ==")
				== "img-e9e218f49b5f4d08"
		)
	}

	@Test
	func differentDataProducesDifferentIDs() {
		let id1 = ImageAttachmentID.predict(mimeType: "image/png", base64Data: "ZmFrZQ==")
		let id2 = ImageAttachmentID.predict(mimeType: "image/png", base64Data: "YWJj")
		#expect(id1 != id2)
	}

	@Test
	func differentMimeTypesProduceDifferentIDs() {
		let png = ImageAttachmentID.predict(mimeType: "image/png", base64Data: "ZmFrZQ==")
		let jpeg = ImageAttachmentID.predict(mimeType: "image/jpeg", base64Data: "ZmFrZQ==")
		#expect(png != jpeg)
	}
}
