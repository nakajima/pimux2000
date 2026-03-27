import Foundation
import GRDB
import GRDBQuery
import SwiftUI

struct Host: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
	static let databaseTableName = "hosts"

	var id: Int64?
	var sshTarget: String
	var createdAt: Date
	var updatedAt: Date

	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}

	var serverURL: String {
		// Extract hostname from user@host
		let host: String
		if let atSign = sshTarget.firstIndex(of: "@") {
			host = String(sshTarget[sshTarget.index(after: atSign)...])
		} else {
			host = sshTarget
		}
		return "ws://\(host):7749"
	}

	var displayName: String {
		sshTarget
	}
}
