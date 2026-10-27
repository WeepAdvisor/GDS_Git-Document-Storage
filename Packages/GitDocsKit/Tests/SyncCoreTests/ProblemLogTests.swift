import XCTest
@testable import SyncCore

final class ProblemLogTests: XCTestCase {
    func testEntriesOlderThanAWeekAreDropped() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "gds-log-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let url = container.appending(path: "Library/Application Support/problem-log.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = ProblemLog.format(kind: "uploadFailed", message: "old", path: "a", domain: "o/r", at: Date().addingTimeInterval(-8 * 24 * 60 * 60))
        try (old + "\n").write(to: url, atomically: true, encoding: .utf8)

        ProblemLog.record(kind: "uploadFailed", message: "new", path: "b", domain: "o/r", container: container)
        let text = try String(contentsOf: XCTUnwrap(ProblemLog.preparedFileURL(container: container)), encoding: .utf8)
        XCTAssertFalse(text.contains("old"))
        XCTAssertTrue(text.contains("new"))
    }

    func testSameProblemIsNotWrittenTwiceWithinFiveMinutes() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "gds-log-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        ProblemLog.record(kind: "pollFailed", message: "timeout", domain: "o/r", container: container)
        ProblemLog.record(kind: "pollFailed", message: "timeout", domain: "o/r", container: container)
        let text = try String(contentsOf: XCTUnwrap(ProblemLog.preparedFileURL(container: container)), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "timeout").count - 1, 1)
    }
}