//
//  Route.swift
//  pimux2000
//
//  Created by Pat Nakajima on 3/26/26.
//

struct MessageContextRoute: Hashable, Identifiable {
	let title: String
	let text: String
	let role: Message.Role

	var id: String {
		var hasher = Hasher()
		hasher.combine(title)
		hasher.combine(text)
		hasher.combine(role)
		return String(hasher.finalize())
	}
}

enum Route: Hashable {
	case piSession(PiSession)
	case messageContext(MessageContextRoute)
}
