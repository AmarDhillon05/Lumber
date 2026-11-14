import XCTest
@testable import LumberCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(LumberCoreInfo.version.isEmpty)
    }
}
