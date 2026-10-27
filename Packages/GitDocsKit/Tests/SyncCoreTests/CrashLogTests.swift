import XCTest
@testable import SyncCore

final class CrashLogTests: XCTestCase {
    func testOldCrashBlocksAreDropped() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "gds-crash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let old = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        CrashLog.record(process: "app", title: "old crash", detail: "stack", container: container, at: old)
        CrashLog.record(process: "app", title: "Sync Now crash", detail: "signal 6", container: container)
        let text = CrashLog.recentText(container: container)
        XCTAssertFalse(text.contains("old crash"))
        XCTAssertTrue(text.contains("Sync Now crash"))
        XCTAssertTrue(text.contains("signal 6"))
    }
}
