import Foundation
import GRDB
import GRDBQuery
import SwiftUI

@main
struct pimux2000App: App {
	let appDatabase: AppDatabase

	init() {
		PimuxImageLoading.configureSharedPipeline()
		let processInfo = ProcessInfo.processInfo

		if Self.isRunningForPreviews {
			self.appDatabase = AppDatabase.preview()
			return
		}

		let databaseURL = Self.databaseURL

		if processInfo.arguments.contains("--uitesting-reset-db") {
			try? FileManager.default.removeItem(at: databaseURL)
			try? AttachmentStore.removeAll()
		}

		try! FileManager.default.createDirectory(
			at: databaseURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)

		self.appDatabase = try! AppDatabase(
			dbQueue: DatabaseQueue(path: databaseURL.path())
		)

		if processInfo.arguments.contains("--uitesting-use-fixtures") {
			try! UITestFixtures.install(in: appDatabase)
		}
	}

	var body: some Scene {
		WindowGroup {
			AppRootView(appDatabase: appDatabase)
		}
	}

	private static var isRunningForPreviews: Bool {
		ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
	}

	private static var databaseURL: URL {
		URL.documentsDirectory.appending(path: "db.sqlite")
	}
}

private struct AppRootView: View {
	let appDatabase: AppDatabase

	@AppStorage("serverURL") private var serverURL: String?
	@State private var pimuxServerClient: PimuxServerClient?
	@State private var configuredServerURL: String?

	var body: some View {
		ContentView()
			.environment(\.appDatabase, appDatabase)
			.environment(\.pimuxServerClient, pimuxServerClient)
			.databaseContext(.readWrite { appDatabase.dbQueue })
			.onAppear {
				updatePimuxServerClient(for: serverURL)
			}
			.onChange(of: serverURL) { _, newValue in
				updatePimuxServerClient(for: newValue)
			}
	}

	private func updatePimuxServerClient(for rawServerURL: String?) {
		let nextServerURL = rawServerURL?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard configuredServerURL != nextServerURL else { return }
		configuredServerURL = nextServerURL

		guard let nextServerURL, !nextServerURL.isEmpty else {
			pimuxServerClient = nil
			return
		}

		do {
			pimuxServerClient = try PimuxServerClient(baseURL: nextServerURL)
		} catch {
			pimuxServerClient = nil
			print("Failed to create pimux server client for \(nextServerURL): \(error)")
		}
	}
}
