// Launches the real app on a simulator and clicks around the screens that
// need no hardware. This is the check that would have caught "closes
// instantly on launch".

import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesToTheLibraryAndOpensRecordings() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your songs"].waitForExistence(timeout: 30), "Library didn't appear")
        attach(app, "library")

        app.staticTexts["Recordings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 10), "Recordings didn't open")
        attach(app, "recordings")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your songs"].waitForExistence(timeout: 10))

        // Still alive a few seconds later (no deferred crash).
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
