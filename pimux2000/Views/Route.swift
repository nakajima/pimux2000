//
//  Route.swift
//  pimux2000
//
//  Created by Pat Nakajima on 3/26/26.
//

struct MessageContextRoute: Hashable {
	let title: String
	let text: String
	let role: Message.Role
}

enum Route: Hashable {
	case piSession(PiSession)
	case messageContext(MessageContextRoute)
}
