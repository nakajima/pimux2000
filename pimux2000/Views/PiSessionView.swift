//
//  PiSessionView.swift
//  pimux2000
//
//  Created by Pat Nakajima on 3/26/26.
//

import SwiftUI
import GRDBQuery
import GRDB

struct MessagesRequest: ValueObservationQueryable {
	static var defaultValue: [Message] { [] }
	
	let session: PiSession

	func fetch(_ db: Database) throws -> [Message] {
		try Message.including(all: Message.contentBlocks).order(Column("createdAt").asc).fetchAll(db)
	}
}

struct PiSessionView: View {
	let session: PiSession
	@Query<MessagesRequest> var messages: [Message]
	
	init(session: PiSession) {
		self.session = session
		self._messages = Query(MessagesRequest(session: session))
	}
	
	var body: some View {
		Text(session.summary)
	}
}
