import XCTest
@testable import SyncCore

final class PathNormalizerTests: XCTestCase {
    func testNFCNormalization() {
        let nfd = "Отче\u{0308}т.docx"      // ё как е + combining diaeresis
        let nfc = PathNormalizer.normalizeName(nfd)
        XCTAssertEqual(nfc, "Отчёт.docx")
        XCTAssertNotEqual(Array(nfd.unicodeScalars).count, Array(nfc.unicodeScalars).count)
    }

    func testValidation() {
        XCTAssertEqual(PathNormalizer.validateName(""), .empty)
        XCTAssertEqual(PathNormalizer.validateName("."), .dotOrDotDot)
        XCTAssertEqual(PathNormalizer.validateName(".."), .dotOrDotDot)
        XCTAssertEqual(PathNormalizer.validateName(".git"), .gitDirectory)
        XCTAssertEqual(PathNormalizer.validateName("a\u{0}b"), .containsNUL)
        XCTAssertEqual(PathNormalizer.validateName("name "), .trailingSpaceOrDot)
        XCTAssertEqual(PathNormalizer.validateName("name."), .trailingSpaceOrDot)
        XCTAssertEqual(PathNormalizer.validateName(String(repeating: "я", count: 200)), .tooLong) // 400 байт
        XCTAssertNil(PathNormalizer.validateName("Report (final).docx"))
        XCTAssertNil(PathNormalizer.validateName(".gitkeep"))
    }

    func testPathHelpers() {
        XCTAssertEqual(PathNormalizer.parentPath(of: "a/b/c.txt"), "a/b")
        XCTAssertEqual(PathNormalizer.parentPath(of: "c.txt"), "")
        XCTAssertEqual(PathNormalizer.fileName(of: "a/b/c.txt"), "c.txt")
        XCTAssertEqual(PathNormalizer.joinPath(["a", "b", "c.txt"]), "a/b/c.txt")
        XCTAssertEqual(PathNormalizer.components(of: "/a//b/"), ["a", "b"])
    }
}
