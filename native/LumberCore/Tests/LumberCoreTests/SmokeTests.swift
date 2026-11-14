import XCTest
@testable import LumberCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(LumberCore.version.isEmpty)
    }
}
