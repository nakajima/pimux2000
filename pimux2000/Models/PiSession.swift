//
//  PiSession.swift
//  pimux2000
//
//  Created by Pat Nakajima on 3/25/26.
//

import Foundation
import GRDB
import GRDBQuery
import SwiftUI

struct PiSession: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
	static let databaseTableName = "piSessions"
	static let messages = hasMany(Message.self)

	var id: Int64?
	var hostID: Int64
	var summary: String
	var sessionID: String
	var sessionFile: String?
	var model: String
	var lastMessage: String?
	var lastMessageAt: Date?
	var lastMessageRole: String?
	var startedAt: Date
	var lastSeenAt: Date

	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}
}
