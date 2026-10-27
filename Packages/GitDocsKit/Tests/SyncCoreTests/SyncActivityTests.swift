import XCTest
@testable import SyncCore

final class SyncActivityTests: XCTestCase {
    private func store() -> UserDefaults {
        UserDefaults(suiteName: "gds-sync-\(UUID().uuidString)")!
    }

    func testUploadFilePercent() {
        let defaults = store()
        let domain = UUID()
        SyncActivity.setFiles(domain: domain, direction: .upload, done: 1, total: 4, defaults: defaults)
        let meters = SyncActivity.current(defaults: defaults)
        XCTAssertEqual(meters.upload.kind, .files)
        XCTAssertEqual(meters.upload.percent, 25)
        XCTAssertEqual(meters.upload.caption, "1 of 4 files")
        XCTAssertEqual(meters.download.kind, .idle)
        XCTAssertEqual(meters.download.percent, 100)
    }

    func testBytesWinOverFileCount() {
        let defaults = store()
        let domain = UUID()
        SyncActivity.setFiles(domain: domain, direction: .download, done: 0, total: 4, defaults: defaults)
        SyncActivity.setBytes(domain: domain, direction: .download, done: 50, total: 200, defaults: defaults)
        let meter = SyncActivity.current(defaults: defaults).download
        XCTAssertEqual(meter.kind, .bytes)
        XCTAssertEqual(meter.percent, 25)
    }

    func testFinishedWorkReturnsToIdle() {
        let defaults = store()
        let domain = UUID()
        let past = Date().addingTimeInterval(-5)
        SyncActivity.setFiles(domain: domain, direction: .upload, done: 3, total: 3, defaults: defaults, now: past)
        let meter = SyncActivity.current(defaults: defaults).upload
        XCTAssertEqual(meter.kind, .idle)
        XCTAssertEqual(meter.percent, 100)
        XCTAssertEqual(meter.caption, "Up to date")
    }

    func testFetchingCaption() {
        let defaults = store()
        SyncActivity.setFiles(domain: UUID(), direction: .download, done: 0, total: 1, defaults: defaults)
        XCTAssertEqual(SyncActivity.current(defaults: defaults).download.caption, "Fetching…")
    }
}
