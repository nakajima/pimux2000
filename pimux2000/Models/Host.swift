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

	var serverHost: String {
		if let atSign = sshTarget.firstIndex(of: "@") {
			return String(sshTarget[sshTarget.index(after: atSign)...])
		}
		return sshTarget
	}

	var serverURL: String {
		"ws://\(serverHost):7749"
	}

	var healthURL: URL? {
		URL(string: "http://\(serverHost):7749/health")
	}

	var displayName: String {
		sshTarget
	}
}
