import LocalSwitchCore
import XCTest

@testable import LocalSwitchMac

@MainActor final class AppModelTests: XCTestCase {
  func testDraftSurvivesNewChatAndCurrentHistorySelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let suite = "LocalSwitch-test-" + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      prefs.removePersistentDomain(forName: suite)
    }
    let secrets = AppMemorySecrets()
    let app = AppModel(
      root: root.appendingPathComponent("Models"), preferences: prefs, historySecrets: secrets,
      chatGPTSecrets: AppMemorySecrets())
    XCTAssertNil(app.error)
    app.draft = "Synthetic unsent private note"
    app.newChat()
    let id = try XCTUnwrap(app.conversations.first?.id)
    XCTAssertEqual(app.conversations.first?.draft, "Synthetic unsent private note")
    app.openConversation(id)
    XCTAssertEqual(app.draft, "Synthetic unsent private note")
    app.draft = "Edited unsent note"
    app.openConversation(id)
    XCTAssertEqual(app.draft, "Edited unsent note")
    app.shutdown()
    let history = try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets)
    XCTAssertEqual(try history.load().first?.draft, "Edited unsent note")
  }
  func testStaleHistoryFailurePreservesDraftAndRecoversSeparateCopy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = AppMemorySecrets()
    let original = UUID()
    let seed = try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets)
    try seed.save([
      SavedConversation(
        id: original, messages: [ChatMessage(role: "user", content: "Synthetic original")])
    ])
    let app = AppModel(
      root: root.appendingPathComponent("Models"), historySecrets: secrets,
      chatGPTSecrets: AppMemorySecrets())
    app.openConversation(original)
    app.draft = "Unsaved recovery draft"
    let peer = try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets)
    try peer.save([
      SavedConversation(
        id: original, messages: [ChatMessage(role: "user", content: "Newer disk revision")])
    ])
    app.newChat()
    XCTAssertFalse(app.historyAvailable)
    XCTAssertEqual(app.draft, "Unsaved recovery draft")
    app.openConversation(original)
    XCTAssertEqual(app.draft, "Unsaved recovery draft")
    app.retryHistoryAccess()
    XCTAssertTrue(app.historyAvailable)
    let loaded = try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets)
      .load()
    XCTAssertEqual(loaded.count, 2)
    XCTAssertEqual(
      loaded.first(where: { $0.id == original })?.messages.first?.content, "Newer disk revision")
    XCTAssertEqual(loaded.first(where: { $0.id != original })?.draft, "Unsaved recovery draft")
  }
  func testDeleteFailureRollsBackAndTemporarySessionIsExplicit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = AppMemorySecrets()
    let app = AppModel(
      root: root.appendingPathComponent("Models"), historySecrets: secrets,
      chatGPTSecrets: AppMemorySecrets())
    app.draft = "Synthetic saved draft"
    app.newChat()
    let id = try XCTUnwrap(app.conversations.first?.id)
    app.openConversation(id)
    app.status = "Finished with ChatGPT"
    secrets.blocked = true
    app.deleteConversation(id)
    XCTAssertFalse(app.historyAvailable)
    XCTAssertEqual(app.draft, "Synthetic saved draft")
    XCTAssertEqual(app.conversations.first?.id, id)
    XCTAssertEqual(app.status, "Finished with ChatGPT")
    app.newChat()
    XCTAssertEqual(app.draft, "Synthetic saved draft")
    XCTAssertFalse(app.temporarySession)
    app.useTemporarySession()
    XCTAssertTrue(app.temporarySession)
    app.newChat()
    XCTAssertTrue(app.draft.isEmpty)
    secrets.blocked = false
    XCTAssertEqual(
      try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets).load().first?
        .draft, "Synthetic saved draft")
  }
  func testOpeningAndDeletingAnotherChatDoesNotInheritPriorCompletionStatus() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = AppMemorySecrets()
    let first = UUID()
    let second = UUID()
    let store = try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets)
    try store.save([
      SavedConversation(
        id: first,
        messages: [
          ChatMessage(role: "assistant", content: "Synthetic cloud answer", route: "chatgpt")
        ]),
      SavedConversation(id: second, messages: [], draft: "A different unsent draft"),
    ])
    let app = AppModel(
      root: root.appendingPathComponent("Models"), historySecrets: secrets,
      chatGPTSecrets: AppMemorySecrets())
    app.openConversation(first)
    app.status = "Finished with ChatGPT"
    app.completionPulse = UUID()
    app.openConversation(second)
    XCTAssertEqual(app.draft, "A different unsent draft")
    XCTAssertEqual(app.status, "Ready when you are")
    XCTAssertNil(app.completionPulse)
    app.status = "Finished on this Mac"
    app.deleteConversation(second)
    XCTAssertTrue(app.messages.isEmpty)
    XCTAssertTrue(app.draft.isEmpty)
    XCTAssertEqual(app.status, "Ready when you are")
    XCTAssertNil(app.completionPulse)
    app.shutdown()
  }
  func testClearedSavedDraftStaysClearedAfterLeavingAndRestarting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let suite = "PipHybrid-test-" + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      prefs.removePersistentDomain(forName: suite)
    }
    let secrets = AppMemorySecrets()
    let app = AppModel(
      root: root.appendingPathComponent("Models"), preferences: prefs,
      historySecrets: secrets, chatGPTSecrets: AppMemorySecrets())
    app.draft = "Synthetic draft that the user clears"
    app.newChat()
    let id = try XCTUnwrap(app.conversations.first?.id)
    app.openConversation(id)
    app.draft = ""
    app.newChat()
    app.openConversation(id)
    XCTAssertTrue(app.draft.isEmpty)
    app.shutdown()
    let reopened = AppModel(
      root: root.appendingPathComponent("Models"), preferences: prefs,
      historySecrets: secrets, chatGPTSecrets: AppMemorySecrets())
    reopened.openConversation(id)
    XCTAssertTrue(reopened.draft.isEmpty)
    XCTAssertNil(
      try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets)
        .load().first(where: { $0.id == id })?.draft)
    reopened.shutdown()
  }
  func testClearedDraftRecoveryPreservesConcurrentDiskRevision() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = AppMemorySecrets()
    let app = AppModel(
      root: root.appendingPathComponent("Models"),
      historySecrets: secrets, chatGPTSecrets: AppMemorySecrets())
    app.draft = "Synthetic saved draft"
    app.newChat()
    let id = try XCTUnwrap(app.conversations.first?.id)
    app.openConversation(id)
    app.draft = ""
    let peer = try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets)
    try peer.save([
      SavedConversation(
        id: id,
        messages: [ChatMessage(role: "user", content: "Synthetic newer peer revision")])
    ])
    app.newChat()
    XCTAssertFalse(app.historyAvailable)
    app.retryHistoryAccess()
    XCTAssertTrue(app.historyAvailable)
    XCTAssertTrue(app.draft.isEmpty)
    app.shutdown()
    let loaded = try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets)
      .load()
    XCTAssertEqual(loaded.count, 2)
    XCTAssertEqual(
      loaded.first(where: { $0.id == id })?.messages.first?.content,
      "Synthetic newer peer revision")
    let recovered = try XCTUnwrap(loaded.first(where: { $0.id != id }))
    XCTAssertTrue(recovered.messages.isEmpty)
    XCTAssertNil(recovered.draft)
    XCTAssertTrue(recovered.title.hasPrefix("Recovered"))
  }
  func testIsolatedAcceptanceCannotBeginRealAccountAuthorization() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AppModel(
      root: root.appendingPathComponent("Models"),
      historySecrets: AppMemorySecrets(), chatGPTSecrets: AppMemorySecrets(),
      accountConnectionsEnabled: false)
    app.startChatGPTSignIn(openBrowser: false)
    XCTAssertFalse(app.chatGPT.isAuthorizing)
    XCTAssertFalse(app.isManagingChatGPT)
    XCTAssertTrue(app.error?.contains("synthetic accounts") == true)
    app.shutdown()
  }
  func testUnavailableStorageFailsReadablyWithoutFallbackWrites() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try Data("Synthetic protected file".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let app = AppModel(root: file, chatGPTSecrets: AppMemorySecrets())
    XCTAssertNotNil(app.error)
    XCTAssertFalse(app.installed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: app.models.root.path))
    XCTAssertEqual(try String(contentsOf: file), "Synthetic protected file")
    app.shutdown()
  }
  func testDeletedCurrentDraftCannotResurrectAtQuit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let suite = "LocalSwitch-test-" + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      prefs.removePersistentDomain(forName: suite)
    }
    let secrets = AppMemorySecrets()
    let app = AppModel(
      root: root.appendingPathComponent("Models"), preferences: prefs, historySecrets: secrets,
      chatGPTSecrets: AppMemorySecrets())
    app.draft = "Synthetic disposable note"
    app.newChat()
    let id = try XCTUnwrap(app.conversations.first?.id)
    app.openConversation(id)
    app.deleteConversation(id)
    XCTAssertEqual(app.draft, "")
    XCTAssertTrue(app.messages.isEmpty)
    app.shutdown()
    XCTAssertTrue(
      try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets).load().isEmpty)
  }
}

final class AppMemorySecrets: SecretStore {
  private var records: [String: Data] = [:]
  var blocked = false
  func read(_ key: String) throws -> Data? {
    if blocked { throw LocalRuntimeError.message("Synthetic storage locked") }
    return records[key]
  }
  func write(_ data: Data, for key: String) throws { records[key] = data }
  func remove(_ key: String) throws { records.removeValue(forKey: key) }
}
