import XCTest
@testable import SyncCore

final class CrashStackTests: XCTestCase {
    func testFrameWalkFollowsSavedLinks() {
        let memory: [UInt64: UInt64] = [
            0x1000: 0x1010,
            0x1008: 0xAAAA,
            0x1010: 0,
            0x1018: 0xBBBB,
        ]
        let frames = CrashStack.collect(pc: 0x1111, lr: 0, fp: 0x1000) { memory[$0] }
        XCTAssertEqual(frames, [0x1111, 0xAAAA, 0xBBBB])
    }

    func testFormatFramesUsesImageNameAndOffset() {
        let lines = CrashStack.formatFrames(
            [0x1050, 0x9],
            images: [(start: 0x1000, end: 0x2000, name: "GDS")]
        )
        XCTAssertEqual(lines, ["GDS + 0x50", "??? + 0x9"])
    }

    func testMetricKitStackIsText() {
        let json = """
        {"callStacks":[
          {"threadAttributed":true,"callStackRootFrames":[
            {"binaryName":"GDS","offsetIntoBinaryTextSegment":100,"subFrames":[
              {"binaryName":"SwiftUI","offsetIntoBinaryTextSegment":200}
            ]}
          ]},
          {"threadAttributed":false,"callStackRootFrames":[]}
        ]}
        """.data(using: .utf8)!
        let text = CrashStack.formatMetricKit(json)
        XCTAssertTrue(text.contains("thread 0 crashed"))
        XCTAssertTrue(text.contains("0 GDS + 100"))
        XCTAssertTrue(text.contains("1 SwiftUI + 200"))
        XCTAssertFalse(text.contains("callStackRootFrames"))
    }

    func testEmptyCrashedThreadIsMarked() {
        let json = """
        {"callStacks":[{"threadAttributed":true,"callStackRootFrames":[]}]}
        """.data(using: .utf8)!
        XCTAssertTrue(CrashStack.formatMetricKit(json).contains("no frames"))
    }

    func testPendingStackIsRenderedOnNextLaunch() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "gds-stack-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let url = container.appending(path: "Library/Application Support/crash-stack-app.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = "S\t11\nF\t0x1050\t0x1000\t/tmp/GDS\n"
        try raw.write(to: url, atomically: true, encoding: .utf8)
        let text = CrashStack.consumePending(process: "app", container: container)
        XCTAssertEqual(text, "signal 11\n0 GDS + 0x50")
    }
}
