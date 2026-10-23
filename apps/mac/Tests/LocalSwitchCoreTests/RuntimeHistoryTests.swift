import XCTest

@testable import LocalSwitchCore

@MainActor final class RuntimeHistoryTests: XCTestCase {
  func testUnicodeStreamDeltaAndTerminal() throws {
    let delta = try LocalRuntime.parseDelta(
      Data(#"{"choices":[{"delta":{"content":"Hi 👋🏽"},"finish_reason":null}]}"#.utf8))
    XCTAssertEqual(delta.text, "Hi 👋🏽")
    XCTAssertFalse(delta.finished)
    XCTAssertTrue(
      try LocalRuntime.parseDelta(Data(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#.utf8))
        .finished)
    XCTAssertThrowsError(
      try LocalRuntime.parseDelta(
        Data(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#.utf8)))
    XCTAssertThrowsError(
      try LocalRuntime.parseDelta(Data(#"{"error":{"message":"failure"}}"#.utf8)))
    XCTAssertThrowsError(try LocalRuntime.parseDelta(Data("not-json".utf8)))
  }
  func testHistoryRecoveryAndPrivatePermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChatStore(root: root, secrets: HistoryTestSecrets())
    XCTAssertEqual(try store.load().count, 0)
    let id = UUID()
    try store.save([
      SavedConversation(
        id: id,
        messages: [
          ChatMessage(role: "user", content: "Synthetic note"),
          ChatMessage(role: "assistant", content: "Partial 👋", state: "streaming"),
        ])
    ])
    let loaded = try store.load()
    XCTAssertEqual(loaded.first?.id, id)
    XCTAssertEqual(loaded.first?.messages.last?.state, "interrupted")
    XCTAssertEqual(loaded.first?.messages.last?.content, "Partial 👋")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
  }
  func testHistoryRefusesSymlinkReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try Data("Keep this".utf8).write(to: outside)
    let store = try ChatStore(root: root, secrets: HistoryTestSecrets())
    try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: outside)
    XCTAssertThrowsError(try store.save([]))
    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(try String(contentsOf: outside), "Keep this")
  }
}
