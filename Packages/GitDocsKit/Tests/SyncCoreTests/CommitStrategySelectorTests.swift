import XCTest
@testable import SyncCore

final class CommitStrategySelectorTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/x")

    private func addition(_ path: String, size: Int64) -> CommitChange {
        .addition(path: path, contentURL: url, mode: "100644", size: size)
    }

    func testSmallBatchUsesGraphQL() {
        let changes = [addition("a.txt", size: 10), addition("b.txt", size: 20), .deletion(path: "c.txt")]
        XCTAssertEqual(CommitStrategySelector.select(for: changes, isEmptyRepository: false), .graphQL)
    }

    func testEmptyRepositoryUsesContentsAPI() {
        XCTAssertEqual(CommitStrategySelector.select(for: [addition("a.txt", size: 1)], isEmptyRepository: true), .contentsAPIFirstFile)
    }

    func testMoveForcesREST() {
        let changes: [CommitChange] = [.move(from: "a.txt", to: "b.txt", blobSHA: "s", mode: "100644")]
        XCTAssertEqual(CommitStrategySelector.select(for: changes, isEmptyRepository: false), .restGitData)
    }

    func testCopyForcesREST() {
        let changes: [CommitChange] = [.copy(to: "b.txt", blobSHA: "s", mode: "100644")]
        XCTAssertEqual(CommitStrategySelector.select(for: changes, isEmptyRepository: false), .restGitData)
    }

    func testEmptyFileForcesREST() {
        XCTAssertEqual(CommitStrategySelector.select(for: [addition("folder/.gitkeep", size: 0)], isEmptyRepository: false), .restGitData)
    }

    func testLargeFileForcesREST() {
        let limits = CommitLimits.default
        let changes = [addition("big.bin", size: limits.graphQLMaxFileBytes + 1)]
        XCTAssertEqual(CommitStrategySelector.select(for: changes, isEmptyRepository: false, limits: limits), .restGitData)
    }

    func testTooManyFilesForcesREST() {
        let limits = CommitLimits.default
        let changes = (0...limits.graphQLMaxFiles).map { addition("f\($0).txt", size: 1) }
        XCTAssertEqual(CommitStrategySelector.select(for: changes, isEmptyRepository: false, limits: limits), .restGitData)
    }

    func testTotalBytesBoundary() {
        let limits = CommitLimits.default
        // Каждый файл ниже per-file лимита, сумма — ровно на границе total-лимита.
        let part: Int64 = 8 * 1024 * 1024
        let rest = limits.graphQLMaxTotalBytes - 2 * part
        XCTAssertLessThan(rest, limits.graphQLMaxFileBytes)
        XCTAssertEqual(CommitStrategySelector.select(for: [addition("a", size: part), addition("b", size: part), addition("c", size: rest)], isEmptyRepository: false, limits: limits), .graphQL)
        XCTAssertEqual(CommitStrategySelector.select(for: [addition("a", size: part), addition("b", size: part), addition("c", size: rest + 1)], isEmptyRepository: false, limits: limits), .restGitData)
    }

    func testHugeFolderIsSplitIntoSmallCommits() {
        let small = (0..<45).map { addition("img\($0).png", size: 200_000) }
        let video = addition("clip.mov", size: 20 * 1024 * 1024)
        let chunks = CommitChunks.split(small + [video])
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.contains { $0.count == 1 && $0.allSatisfy { change in
            if case .addition(let path, _, _, _) = change { return path == "clip.mov" }
            return false
        } })
        XCTAssertTrue(chunks.allSatisfy { $0.count <= CommitChunks.maxFiles })
    }
}
