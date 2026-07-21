import XCTest
@testable import FastDocReader

final class MermaidCacheTests: XCTestCase {
    func testKeyIsStableAndContentAddressed() {
        let a = MermaidCache.key(source: "graph TD; A-->B", version: "10")
        let b = MermaidCache.key(source: "graph TD; A-->B", version: "10")
        let c = MermaidCache.key(source: "graph TD; A-->C", version: "10")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testVersionChangesKey() {
        XCTAssertNotEqual(MermaidCache.key(source: "x", version: "10"),
                          MermaidCache.key(source: "x", version: "11"))
    }

    func testStoreAndRetrieveRoundTrips() {
        let key = MermaidCache.key(source: "roundtrip-\(ProcessInfo.processInfo.globallyUniqueString)", version: "10")
        XCTAssertNil(MermaidCache.pdf(forKey: key))
        let data = Data("%PDF-1.4 fake".utf8)
        MermaidCache.store(data, forKey: key)
        XCTAssertEqual(MermaidCache.pdf(forKey: key), data)
        try? FileManager.default.removeItem(at: MermaidCache.url(forKey: key))
    }
}
