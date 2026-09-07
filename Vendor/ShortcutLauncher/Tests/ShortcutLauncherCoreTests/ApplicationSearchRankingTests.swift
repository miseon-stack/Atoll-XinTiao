import XCTest

@testable import ShortcutLauncherCore

final class ApplicationSearchRankingTests: XCTestCase {
  private let documents = [
    ApplicationSearchDocument(
      id: "wechat",
      displayName: "微信",
      bundleIdentifier: "com.tencent.xinWeChat",
      searchableAliases: ["WeChat"]
    ),
    ApplicationSearchDocument(
      id: "safari",
      displayName: "Safari",
      bundleIdentifier: "com.apple.Safari"
    ),
    ApplicationSearchDocument(
      id: "settings",
      displayName: "系统设置",
      bundleIdentifier: "com.apple.systempreferences",
      searchableAliases: ["System Settings"]
    ),
  ]

  func testChinesePinyinInitialAliasAndBundleQueriesFindWeChat() {
    for query in ["微信", "微", "weixin", "wei", "wx", "wechat", "tencent"] {
      XCTAssertEqual(ApplicationSearchRanking.rank(documents, for: query).first?.id, "wechat", query)
    }
  }

  func testDocumentNameMatchOutranksAliasAndBundleMatches() {
    let candidates = [
      ApplicationSearchDocument(id: "exact", displayName: "Safari"),
      ApplicationSearchDocument(id: "alias", displayName: "Browser", searchableAliases: ["Safari"]),
      ApplicationSearchDocument(id: "bundle", displayName: "Other", bundleIdentifier: "org.safari.helper"),
    ]

    XCTAssertEqual(
      ApplicationSearchRanking.rank(candidates, for: "safari").map(\.id),
      ["exact", "alias", "bundle"]
    )
  }

  func testCaseWidthAndDiacriticsAreNormalized() {
    let candidates = [
      ApplicationSearchDocument(id: "accent", displayName: "Café"),
      ApplicationSearchDocument(id: "width", displayName: "ＳＡＦＡＲＩ"),
    ]

    XCTAssertEqual(ApplicationSearchRanking.rank(candidates, for: "CAFE").map(\.id), ["accent"])
    XCTAssertEqual(ApplicationSearchRanking.rank(candidates, for: "safari").map(\.id), ["width"])
  }

  func testEmptyQueryAndEqualScoresUseStableTieBreakers() {
    let candidates = [
      ApplicationSearchDocument(id: "z", displayName: "Beta"),
      ApplicationSearchDocument(id: "b", displayName: "Alpha", bundleIdentifier: "org.z"),
      ApplicationSearchDocument(id: "a", displayName: "Alpha", bundleIdentifier: "org.z"),
      ApplicationSearchDocument(id: "c", displayName: "Alpha", bundleIdentifier: "org.a"),
    ]

    let expected = ["c", "a", "b", "z"]
    XCTAssertEqual(ApplicationSearchRanking.rank(candidates, for: "").map(\.id), expected)
    XCTAssertEqual(ApplicationSearchRanking.rank(candidates, for: "a").map(\.id), expected)
  }

  func testNoMatchIsExcludedAndScoreIsNil() {
    let safari = documents[1]
    XCTAssertTrue(ApplicationSearchRanking.rank(documents, for: "nonexistent").isEmpty)
    XCTAssertNil(ApplicationSearchRanking.score(safari, for: "nonexistent"))
    XCTAssertEqual(ApplicationSearchRanking.score(safari, for: ""), 0)
  }
}
