import XCTest
@testable import FastMDReader

final class FontSizeStoreTests: XCTestCase {
    override func setUp() { UserDefaults.standard.removeObject(forKey: "baseFontSize") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "baseFontSize") }

    func testDefaultIs16() { XCTAssertEqual(FontSizeStore.size, 16) }   // Notion base size

    func testIncreaseAndPersist() {
        FontSizeStore.increase()
        XCTAssertEqual(FontSizeStore.size, 17)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "baseFontSize"), 17)
    }

    func testClampUpper() {
        FontSizeStore.size = 100
        XCTAssertEqual(FontSizeStore.size, 36)
    }

    func testClampLower() {
        FontSizeStore.size = 1
        XCTAssertEqual(FontSizeStore.size, 10)
    }
}
