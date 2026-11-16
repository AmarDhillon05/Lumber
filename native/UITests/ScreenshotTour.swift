// Walks the demo library (launch argument -LumberDemo) through Library,
// Record and Edit, saving a screenshot of each screen. Besides the xcresult
// attachments, the PNGs are written to ~/lumber-shots on the Mac running the
// simulator, which CI uploads as the "native-screenshots" artifact, so the
// look of every build can be checked without a phone.

import XCTest

final class ScreenshotTour: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTourTheMainScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-LumberDemo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Demo groove"].waitForExistence(timeout: 30), "demo library didn't load")
        shot(app, "01-library")

        app.buttons["Record"].firstMatch.tap()
        sleep(3)
        shot(app, "02-record")
        app.swipeUp()
        sleep(1)
        shot(app, "03-record-scrolled")
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Edit ›"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Edit ›"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Auto mix"].waitForExistence(timeout: 30), "Edit didn't load")
        sleep(2)
        shot(app, "04-edit")
        for i in 5...9 {
            app.swipeUp()
            sleep(1)
            shot(app, String(format: "%02d-edit-scrolled", i))
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let image = app.screenshot()
        let a = XCTAttachment(screenshot: image)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            let dir = URL(fileURLWithPath: home).appendingPathComponent("lumber-shots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
