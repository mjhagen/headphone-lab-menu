import Foundation
import XCTest

@testable import HeadphoneEQ

final class AutoEqCatalogTests: XCTestCase {
  func testParsesAutoEqIndexEntries() throws {
    let entries = try AutoEqIndexParser.parse(
      """
      # Index
      - [Sennheiser HD25-1 II](./oratory1990/over-ear/Sennheiser%20HD25-1%20II) by oratory1990
      - [Sennheiser HD 25 Plus](./crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%2025%20Plus) by crinacle on GRAS 43AG-7
      """
    )

    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].name, "Sennheiser HD25-1 II")
    XCTAssertEqual(
      entries[0].relativePath,
      "oratory1990/over-ear/Sennheiser%20HD25-1%20II"
    )
    XCTAssertEqual(entries[0].source, "oratory1990")
    XCTAssertEqual(entries[1].source, "crinacle on GRAS 43AG-7")
  }

  func testRejectsEmptyIndex() {
    XCTAssertThrowsError(try AutoEqIndexParser.parse("# No profiles")) { error in
      XCTAssertEqual(error as? AutoEqCatalogError, .invalidIndex)
    }
  }

  func testBuildsParametricProfileURL() async throws {
    let client = AutoEqCatalogClient()
    let entry = AutoEqEntry(
      name: "Sennheiser HD25-1 II",
      relativePath: "oratory1990/over-ear/Sennheiser%20HD25-1%20II",
      source: "oratory1990"
    )

    let url = try await client.profileURL(for: entry)
    XCTAssertEqual(
      url.absoluteString,
      "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD25-1%20II/Sennheiser%20HD25-1%20II%20ParametricEQ.txt"
    )
  }

  func testRejectsPathTraversal() async {
    let client = AutoEqCatalogClient()
    let entry = AutoEqEntry(name: "Invalid", relativePath: "../Invalid", source: "test")
    do {
      _ = try await client.profileURL(for: entry)
      XCTFail("Expected invalid path error")
    } catch {
      XCTAssertEqual(error as? AutoEqCatalogError, .invalidPath("../Invalid"))
    }
  }
}
