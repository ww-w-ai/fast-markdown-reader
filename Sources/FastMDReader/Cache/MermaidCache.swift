import Foundation
import CryptoKit

/// Content-addressed disk cache for rendered mermaid diagrams (PDF, vector).
/// Key = sha256(source + "|" + version) so any edit to the diagram or a mermaid
/// version bump changes the key = automatic invalidation. Lives in the system temp
/// dir: a pure cache the user never sees; the OS may evict it and we regenerate.
enum MermaidCache {
    private static var dir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fast-md-reader/mermaid", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func key(source: String, version: String) -> String {
        let digest = SHA256.hash(data: Data((source + "|" + version).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func url(forKey key: String) -> URL { dir.appendingPathComponent(key + ".pdf") }

    static func pdf(forKey key: String) -> Data? { try? Data(contentsOf: url(forKey: key)) }

    static func store(_ pdf: Data, forKey key: String) { try? pdf.write(to: url(forKey: key)) }
}
