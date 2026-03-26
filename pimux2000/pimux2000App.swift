//
//  pimux2000App.swift
//  pimux2000
//
//  Created by Pat Nakajima on 3/22/26.
//

import GRDB
import GRDBQuery
import SwiftUI

@main
struct pimux2000App: App {
	let appDatabase: AppDatabase

	init() {
		appDatabase = try! AppDatabase(
			dbQueue: DatabaseQueue(path: URL.documentsDirectory.appending(path: "db.sqlite").path())
		)
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
				.environment(\.appDatabase, appDatabase)
				.databaseContext(.readWrite { appDatabase.dbQueue })
		}
	}
}
