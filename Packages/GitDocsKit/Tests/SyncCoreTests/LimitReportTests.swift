import XCTest
@testable import Persistence
@testable import SyncCore

final class LimitReportTests: XCTestCase {
    func testRefreshListsOnlyFilesOverTheGitHubLimit() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "gds-limit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let paths = SharedPaths(testingContainer: container)
        let repo = RepoConfig(owner: "o", repo: "r", branch: "main", accountID: "github.com:me", displayName: "Docs")
        try RepoConfigStore(fileURL: paths.reposConfigURL).save(AppConfiguration(repos: [repo]))
        let store = try DomainStore(at: paths.storeURL(repo.id))
        let items = ItemStore(domain: store)
        let huge = StoredItem(
            id: "huge", parentID: ItemStore.rootID, name: "clip.mp4", path: "Videos/clip.mp4", isDirectory: false,
            blobSHA: nil, size: 200_000_000, mode: "100644", contentMtime: Date(), metaRev: 0, state: .uploadFailed,
            localSHA: nil, isIgnored: false
        )
        let small = StoredItem(
            id: "small", parentID: ItemStore.rootID, name: "a.png", path: "a.png", isDirectory: false,
            blobSHA: nil, size: 20_000, mode: "100644", contentMtime: Date(), metaRev: 0, state: .uploadFailed,
            localSHA: nil, isIgnored: false
        )
        try items.insert(huge, recordChanges: false)
        try items.insert(small, recordChanges: false)

        let found = LimitReport.refresh(container: container)
        XCTAssertEqual(found.map(\.path), ["Videos/clip.mp4"])
        XCTAssertEqual(found.first?.bytes, 200_000_000)
    }
}
