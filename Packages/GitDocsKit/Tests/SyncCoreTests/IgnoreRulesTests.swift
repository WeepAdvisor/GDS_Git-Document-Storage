import XCTest
@testable import SyncCore

final class IgnoreRulesTests: XCTestCase {
    let rules = IgnoreRules.default

    func testFinderAndSystemFiles() {
        XCTAssertTrue(rules.isIgnoredName(".DS_Store"))
        XCTAssertTrue(rules.isIgnoredName("._Report.docx"))
        XCTAssertTrue(rules.isIgnoredName(".Spotlight-V100"))
        XCTAssertTrue(rules.isIgnoredName("Icon\r"))
        XCTAssertTrue(rules.isIgnoredName(".git"))
    }

    func testOfficeAndEditorLocks() {
        XCTAssertTrue(rules.isIgnoredName("~$Budget.xlsx"))
        XCTAssertTrue(rules.isIgnoredName(".~lock.doc.odt#"))
        XCTAssertTrue(rules.isIgnoredName(".#notes.txt"))
        XCTAssertTrue(rules.isIgnoredName("Report.docx.sb-1a2b3c-XyZ"))
    }

    func testTemporaryDownloads() {
        XCTAssertTrue(rules.isIgnoredName("a.TMP"))
        XCTAssertTrue(rules.isIgnoredName("movie.mp4.crdownload"))
        XCTAssertTrue(rules.isIgnoredName("x.part"))
    }

    func testRegularFilesPass() {
        XCTAssertFalse(rules.isIgnoredName("Report.docx"))
        XCTAssertFalse(rules.isIgnoredName(".gitignore"))
        XCTAssertFalse(rules.isIgnoredName(".gitkeep"))
        XCTAssertFalse(rules.isIgnoredName("template.tmpl"))
        XCTAssertFalse(rules.isIgnoredName("git"))
    }

    func testPathChecksEveryComponent() {
        XCTAssertTrue(rules.isIgnoredPath("docs/.git/config"))
        XCTAssertTrue(rules.isIgnoredPath("a/b/.DS_Store"))
        XCTAssertFalse(rules.isIgnoredPath("a/b/c.txt"))
    }
}
