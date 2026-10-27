import Foundation

/// JSON с полем `content` в base64, записанный на диск кусками, без копии файла в памяти.
public enum JSONBase64Body {
    public static func write(source: URL, prefix: String, suffix: String, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: Data(prefix.utf8))
        let chunkSize = 3 * 32 * 1024
        while true {
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try output.write(contentsOf: Data(chunk.base64EncodedString().utf8))
        }
        try output.write(contentsOf: Data(suffix.utf8))
    }
}
