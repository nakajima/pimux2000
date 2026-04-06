import XCTest
#if canImport(UIKit)
	import UIKit
#endif

final class ScreenshotTests: XCTestCase {
	override func setUpWithError() throws {
		continueAfterFailure = false
	}

	@MainActor
	func testAppOverviewScreenshot() throws {
		let app = launchApp(for: "overview")
		openSession(named: "Ship screenshot workflow", in: app)

		let readyText = app.staticTexts["Stable fixtures and a screenshot script are ready."]
		XCTAssertTrue(readyText.waitForExistence(timeout: 5))

		captureScreenshot(named: "app-overview")
	}

	@MainActor
	func testTranscriptScreenshot() throws {
		let app = launchApp(for: "transcript")
		openSession(named: "Programmatic screenshot workflow", in: app)

		let readyText = app.staticTexts["Done — added screenshot scenarios and an export script so the app can generate repeatable screenshots."]
		XCTAssertTrue(readyText.waitForExistence(timeout: 5))

		captureScreenshot(named: "transcript")
	}

	@MainActor
	func testSlashCommandsScreenshot() throws {
		let app = launchApp(for: "slash-commands")
		openSession(named: "Programmatic screenshot workflow", in: app)

		let composer = app.textFields["Send a message"]
		XCTAssertTrue(composer.waitForExistence(timeout: 5))
		composer.tap()
		composer.typeText("/")

		let compactCommand = app.staticTexts["/compact"]
		XCTAssertTrue(compactCommand.waitForExistence(timeout: 3))

		captureScreenshot(named: "slash-commands")
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

		configureDeviceOrientation()
		app.launch()
		XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
		configureDeviceOrientation()

		return app
	}

	private func openSession(named summary: String, in app: XCUIApplication) {
		showSidebarIfNeeded(in: app)

		let sessionCell = app.staticTexts[summary]
		XCTAssertTrue(sessionCell.waitForExistence(timeout: 5))
		sessionCell.tap()
	}

	private func configureDeviceOrientation() {
		XCUIDevice.shared.orientation = isPadDevice ? .landscapeLeft : .portrait
	}

	private func showSidebarIfNeeded(in app: XCUIApplication) {
		let showSidebarButton = app.buttons["Show Sidebar"]
		guard showSidebarButton.waitForExistence(timeout: 1) else { return }
		showSidebarButton.tap()
	}

	private var isPadDevice: Bool {
		#if canImport(UIKit)
			UIDevice.current.userInterfaceIdiom == .pad
		#else
			false
		#endif
	}

	private func captureScreenshot(named name: String) {
		let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
