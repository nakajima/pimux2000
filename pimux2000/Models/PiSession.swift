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
	static let host = belongsTo(Host.self)

	var id: Int64?
	var hostID: Int64
	var summary: String
	var sessionID: String
	var sessionFile: String?
	var model: String
	var cwd: String? = nil
	var lastMessage: String?
	var lastUserMessageAt: Date? = nil
	var lastMessageAt: Date?
	var lastMessageRole: String?
	var lastReadMessageAt: Date? = nil
	var isCliActive: Bool = false
	var contextTokensUsed: Int? = nil
	var contextTokensMax: Int? = nil
	var startedAt: Date
	var lastSeenAt: Date

	var isUnread: Bool {
		guard let lastMessageAt else { return false }
		guard let lastReadMessageAt else { return true }
		return lastReadMessageAt < lastMessageAt
	}

	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}
}
