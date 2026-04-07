import XCTest
#if canImport(UIKit)
	import UIKit
	import UniformTypeIdentifiers
#endif

final class ScreenshotTests: XCTestCase {
	override func setUpWithError() throws {
		continueAfterFailure = false
	}

	@MainActor
	func testAppOverviewScreenshot() throws {
		let app = launchApp(for: "overview")
		openSession(named: "SSH password authentication prompt implementation", in: app)

		let readyText = app.staticTexts["Auth failures now short-circuit cleanly and the password prompt appears."]
		XCTAssertTrue(readyText.waitForExistence(timeout: 5))

		captureScreenshot(named: "app-overview", in: app)
	}

	@MainActor
	func testTranscriptScreenshot() throws {
		let app = launchApp(for: "transcript")
		openSession(named: "iOS app slash command menu feature", in: app)

		let readyText = app.staticTexts["Done — the composer now shows built-in and live session commands in a slash menu."]
		XCTAssertTrue(readyText.waitForExistence(timeout: 5))

		captureScreenshot(named: "transcript", in: app)
	}

	@MainActor
	func testSlashCommandsScreenshot() throws {
		let app = launchApp(for: "slash-commands")
		openSession(named: "iOS app slash command menu feature", in: app)
		hideSidebarIfNeeded(in: app)

		let composer = app.textFields["Send a message"]
		XCTAssertTrue(composer.waitForExistence(timeout: 5))
		composer.tap()
		composer.typeText("/")

		let compactCommand = app.staticTexts["/compact"]
		XCTAssertTrue(compactCommand.waitForExistence(timeout: 3))

		captureScreenshot(named: "slash-commands", in: app)
	}

	private func launchApp(for scenario: String) -> XCUIApplication {
		let app = XCUIApplication()
		app.terminate()
		app.launchArguments += [
			"--uitesting-reset-db",
			"--screenshot-scenario", scenario,
			"-AppleLanguages", "(en)",
			"-AppleLocale", "en_US",
			"-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
		]
		app.launchEnvironment["TZ"] = "UTC"
		app.launchArguments += [
			"--uitesting-force-dark-mode",
			"--uitesting-force-landscape",
		]

		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
		configureDeviceOrientation(in: app)

		return app
	}

	private func openSession(named summary: String, in app: XCUIApplication) {
		showSidebarIfNeeded(in: app)

		let sessionCell = app.staticTexts[summary]
		XCTAssertTrue(sessionCell.waitForExistence(timeout: 5))
		sessionCell.tap()
	}

	private func configureDeviceOrientation(in app: XCUIApplication) {
		let targetOrientation: UIDeviceOrientation = isPadLayout(in: app) ? .landscapeLeft : .portrait
		XCUIDevice.shared.orientation = targetOrientation
		waitForWindowOrientation(in: app, targetOrientation: targetOrientation)
	}

	private func showSidebarIfNeeded(in app: XCUIApplication) {
		let showSidebarButton = app.buttons["Show Sidebar"]
		guard showSidebarButton.waitForExistence(timeout: 1) else { return }
		showSidebarButton.tap()
	}

	private func hideSidebarIfNeeded(in app: XCUIApplication) {
		guard isPadLayout(in: app) else { return }
		let toggleSidebarButton = app.buttons["Toggle Sidebar"]
		guard toggleSidebarButton.waitForExistence(timeout: 1) else { return }
		toggleSidebarButton.tap()
		_ = app.buttons["Show Sidebar"].waitForExistence(timeout: 2)
	}

	private func isPadLayout(in app: XCUIApplication) -> Bool {
		let frame = app.windows.element(boundBy: 0).frame
		return max(frame.width, frame.height) >= 1000
	}

	private func waitForWindowOrientation(in app: XCUIApplication, targetOrientation: UIDeviceOrientation) {
		let deadline = Date().addingTimeInterval(5)
		while Date() < deadline {
			let frame = app.windows.element(boundBy: 0).frame
			if targetOrientation.isLandscape {
				if frame.width > frame.height { return }
			} else if frame.height > frame.width {
				return
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.1))
		}
	}

	private func captureScreenshot(named name: String, in app: XCUIApplication) {
		if signalExternalCaptureIfRequested(named: name) {
			return
		}

		let screenshot = app.screenshot()

		#if canImport(UIKit)
			let image = normalizedScreenshotImage(from: screenshot.image)
			let attachment = XCTAttachment(data: image.pngData()!, uniformTypeIdentifier: UTType.png.identifier)
		#else
			let attachment = XCTAttachment(screenshot: screenshot)
		#endif

		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	private func signalExternalCaptureIfRequested(named name: String) -> Bool {
		let configURL = URL(fileURLWithPath: "/tmp/pimux2000-screenshot-signal-dir.txt")
		guard let signalDirectoryPath = try? String(contentsOf: configURL)
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!signalDirectoryPath.isEmpty
		else {
			return false
		}

		let signalDirectoryURL = URL(fileURLWithPath: signalDirectoryPath, isDirectory: true)
		let readyURL = signalDirectoryURL.appending(path: "\(name).ready")
		let capturedURL = signalDirectoryURL.appending(path: "\(name).captured")

		do {
			try FileManager.default.createDirectory(at: signalDirectoryURL, withIntermediateDirectories: true)
			try Data().write(to: readyURL)
		} catch {
			XCTFail("Failed to signal external capture readiness for \(name): \(error)")
			return true
		}

		let deadline = Date().addingTimeInterval(30)
		while Date() < deadline {
			if FileManager.default.fileExists(atPath: capturedURL.path()) {
				return true
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.1))
		}

		XCTFail("Timed out waiting for external screenshot capture of \(name)")
		return true
	}

	#if canImport(UIKit)
		private func normalizedScreenshotImage(from image: UIImage) -> UIImage {
			let renderer = UIGraphicsImageRenderer(size: image.size)
			return renderer.image { _ in
				image.draw(in: CGRect(origin: .zero, size: image.size))
			}
		}
	#endif
}
