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
		openSession(named: "Ship screenshot workflow", in: app)

		let readyText = app.staticTexts["Stable fixtures and a screenshot script are ready."]
		XCTAssertTrue(readyText.waitForExistence(timeout: 5))

		captureScreenshot(named: "app-overview", in: app)
	}

	@MainActor
	func testTranscriptScreenshot() throws {
		let app = launchApp(for: "transcript")
		openSession(named: "Programmatic screenshot workflow", in: app)

		let readyText = app.staticTexts["Done — added screenshot scenarios and an export script so the app can generate repeatable screenshots."]
		XCTAssertTrue(readyText.waitForExistence(timeout: 5))

		captureScreenshot(named: "transcript", in: app)
	}

	@MainActor
	func testSlashCommandsScreenshot() throws {
		let app = launchApp(for: "slash-commands")
		openSession(named: "Programmatic screenshot workflow", in: app)
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
		app.launchArguments += ["--uitesting-force-dark-mode"]
		if isPadDevice {
			app.launchArguments += ["--uitesting-force-landscape"]
		}

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

	private func hideSidebarIfNeeded(in app: XCUIApplication) {
		guard isPadDevice else { return }
		let toggleSidebarButton = app.buttons["Toggle Sidebar"]
		guard toggleSidebarButton.waitForExistence(timeout: 1) else { return }
		toggleSidebarButton.tap()
		_ = app.buttons["Show Sidebar"].waitForExistence(timeout: 2)
	}

	private var isPadDevice: Bool {
		#if canImport(UIKit)
			UIDevice.current.userInterfaceIdiom == .pad
		#else
			false
		#endif
	}

	private func captureScreenshot(named name: String, in app: XCUIApplication) {
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

	#if canImport(UIKit)
		private func normalizedScreenshotImage(from image: UIImage) -> UIImage {
			let renderer = UIGraphicsImageRenderer(size: image.size)
			return renderer.image { _ in
				image.draw(in: CGRect(origin: .zero, size: image.size))
			}
		}
	#endif
}
