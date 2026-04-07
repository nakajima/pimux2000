import Foundation
import GRDB
import GRDBQuery
import SwiftUI
#if canImport(UIKit)
	import UIKit
#endif

@main
struct pimux2000App: App {
	#if canImport(UIKit)
		@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	#endif
	let appDatabase: AppDatabase

	init() {
		PimuxImageLoading.configureSharedPipeline()
		let processInfo = ProcessInfo.processInfo
		let screenshotScenario = ScreenshotScenario.current(from: processInfo)

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

		if let screenshotScenario {
			try! UITestFixtures.installScreenshotScenario(screenshotScenario, in: appDatabase)
		} else if processInfo.arguments.contains("--uitesting-use-fixtures") {
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

#if canImport(UIKit)
	private final class AppDelegate: NSObject, UIApplicationDelegate {
		func application(
			_ application: UIApplication,
			supportedInterfaceOrientationsFor window: UIWindow?
		) -> UIInterfaceOrientationMask {
			let arguments = ProcessInfo.processInfo.arguments
			guard arguments.contains("--uitesting-force-landscape") else {
				return .all
			}
			guard UIDevice.current.userInterfaceIdiom == .pad else {
				return .allButUpsideDown
			}
			return .landscape
		}
	}
#endif

private struct AppRootView: View {
	let appDatabase: AppDatabase

	@AppStorage("serverURL") private var serverURL: String?
	@State private var pimuxServerClient: PimuxServerClient?
	@State private var configuredServerURL: String?
	@State private var hasRequestedScreenshotLandscape = false
	private let forceDarkMode = ProcessInfo.processInfo.arguments.contains("--uitesting-force-dark-mode")

	var body: some View {
		ContentView()
			.environment(\.appDatabase, appDatabase)
			.environment(\.pimuxServerClient, pimuxServerClient)
			.databaseContext(.readWrite { appDatabase.dbQueue })
			.preferredColorScheme(forceDarkMode ? .dark : nil)
			.onAppear {
				updatePimuxServerClient(for: serverURL)
			}
			.onChange(of: serverURL) { _, newValue in
				updatePimuxServerClient(for: newValue)
			}
			.task {
				await requestScreenshotLandscapeIfNeeded()
			}
	}

	@MainActor
	private func requestScreenshotLandscapeIfNeeded() {
		guard !hasRequestedScreenshotLandscape else { return }
		hasRequestedScreenshotLandscape = true

		#if canImport(UIKit)
			guard ProcessInfo.processInfo.arguments.contains("--uitesting-force-landscape") else { return }
			guard UIDevice.current.userInterfaceIdiom == .pad else { return }
			guard let windowScene = UIApplication.shared.connectedScenes
				.compactMap({ $0 as? UIWindowScene })
				.first else { return }

			let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
			windowScene.requestGeometryUpdate(preferences) { error in
				print("Failed to request screenshot landscape orientation: \(error)")
			}
		#endif
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
