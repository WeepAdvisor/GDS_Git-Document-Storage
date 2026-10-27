import CryptoKit
import Foundation

public enum GitBlobSHA {
    /// SHA-1 пустого blob. Единственный легитимный файл нулевого размера.
    public static let empty = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"

    /// SHA-1 git blob (`blob <size>\0` + bytes). Совпадает с SHA, который вернёт GitHub.
    public static func sha1(of data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha1(ofFile url: URL) throws -> String {
        let count = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(count)\0".utf8))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
