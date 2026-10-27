import XCTest
@testable import Persistence

final class PendingOpsCoalescerTests: XCTestCase {
    func testCreateThenModifyIsOneAddition() {
        let item = sample(id: "1", path: "a.txt")
        let ops = [
            PendingOp(itemID: "1", kind: .create, pathAfter: "a.txt", stagingFile: "/tmp/1", createdAt: Date(timeIntervalSince1970: 1)),
            PendingOp(itemID: "1", kind: .modifyContent, pathAfter: "a.txt", stagingFile: "/tmp/2", createdAt: Date(timeIntervalSince1970: 2)),
        ]
        XCTAssertEqual(PendingOpsCoalescer.coalesce(ops, items: ["1": item]), [.addition(path: "a.txt", stagingFile: "/tmp/2", mode: "100644")])
    }

    func testCreateThenDeleteDisappears() {
        let ops = [
            PendingOp(itemID: "1", kind: .create, pathAfter: "a.txt", stagingFile: "/tmp/1", createdAt: Date(timeIntervalSince1970: 1)),
            PendingOp(itemID: "1", kind: .delete, pathBefore: "a.txt", createdAt: Date(timeIntervalSince1970: 2)),
        ]
        XCTAssertEqual(PendingOpsCoalescer.coalesce(ops, items: [:]), [])
    }

    func testModifyThenDeleteIsDeletion() {
        let item = sample(id: "1", path: "a.txt")
        let ops = [
            PendingOp(itemID: "1", kind: .modifyContent, pathBefore: "a.txt", pathAfter: "a.txt", stagingFile: "/tmp/1", createdAt: Date(timeIntervalSince1970: 1)),
            PendingOp(itemID: "1", kind: .delete, pathBefore: "a.txt", createdAt: Date(timeIntervalSince1970: 2)),
        ]
        XCTAssertEqual(PendingOpsCoalescer.coalesce(ops, items: ["1": item]), [.deletion(path: "a.txt")])
    }

    func testDirectoryRenameWithoutBlobProducesNothing() {
        let folder = StoredItem(id: "dir", parentID: ItemStore.rootID, name: "B", path: "B", isDirectory: true,
                                blobSHA: nil, size: 0, mode: "040000", contentMtime: Date(), metaRev: 1,
                                state: .synced, localSHA: nil, isIgnored: false)
        let ops = [
            PendingOp(itemID: "dir", kind: .rename, pathBefore: "A", pathAfter: "B", createdAt: Date(timeIntervalSince1970: 1)),
        ]
        XCTAssertEqual(PendingOpsCoalescer.coalesce(ops, items: ["dir": folder]), [])
    }

    func testRebaseKeepsSiblingPrefix() {
        XCTAssertEqual(PendingOpsStore.rebase("Foo/.gitkeep", from: "Foo", to: "Bar"), "Bar/.gitkeep")
        XCTAssertEqual(PendingOpsStore.rebase("Foo/sub/a.txt", from: "Foo", to: "Bar"), "Bar/sub/a.txt")
        XCTAssertEqual(PendingOpsStore.rebase("Food/.gitkeep", from: "Foo", to: "Bar"), "Food/.gitkeep")
        XCTAssertEqual(PendingOpsStore.rebase("Foo", from: "Foo", to: "Bar"), "Bar")
    }

    func testRenameThenRenameCollapses() {
        let item = sample(id: "1", path: "a.txt", sha: "abc")
        let ops = [
            PendingOp(itemID: "1", kind: .rename, pathBefore: "a.txt", pathAfter: "b.txt", createdAt: Date(timeIntervalSince1970: 1)),
            PendingOp(itemID: "1", kind: .rename, pathBefore: "b.txt", pathAfter: "c.txt", createdAt: Date(timeIntervalSince1970: 2)),
        ]
        XCTAssertEqual(
            PendingOpsCoalescer.coalesce(ops, items: ["1": item]),
            [.move(from: "a.txt", to: "c.txt", blobSHA: "abc", mode: "100644")]
        )
    }

    private func sample(id: String, path: String, sha: String? = nil) -> StoredItem {
        StoredItem(id: id, parentID: ItemStore.rootID, name: path, path: path, isDirectory: false, blobSHA: sha, size: 1,
                   mode: "100644", contentMtime: Date(), metaRev: 0, state: .synced, localSHA: nil, isIgnored: false)
    }
}
