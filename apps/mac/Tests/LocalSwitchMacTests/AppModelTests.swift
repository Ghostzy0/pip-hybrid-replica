import Darwin
@testable import LocalSwitchCore
import XCTest

@testable import LocalSwitchMac

@MainActor final class AppModelTests: XCTestCase {
  func testExplicitChatGPTModelPreferenceSurvivesAppModelReload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let suite = "LocalSwitch-model-choice-" + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      prefs.removePersistentDomain(forName: suite)
    }
    prefs.set("synthetic-remembered-model", forKey: "selectedChatGPTModel")
    let first = AppModel(
      root: root.appendingPathComponent("Models"), preferences: prefs,
      historySecrets: AppMemorySecrets(), chatGPTSecrets: AppMemorySecrets())
    XCTAssertEqual(first.selectedChatGPTModel, "synthetic-remembered-model")

    first.selectedChatGPTModel = "synthetic-explicit-choice"
    XCTAssertEqual(prefs.string(forKey: "selectedChatGPTModel"), "synthetic-explicit-choice")
    first.shutdown()

    let reopened = AppModel(
      root: root.appendingPathComponent("Models"), preferences: prefs,
      historySecrets: AppMemorySecrets(), chatGPTSecrets: AppMemorySecrets())
    XCTAssertEqual(reopened.selectedChatGPTModel, "synthetic-explicit-choice")
    reopened.shutdown()
  }

  func testChatGPTModelResolutionUsesRememberedThenListedLunaThenFirst() {
    let catalogue = [
      ChatGPTModel(slug: "synthetic-first", displayName: "First listed"),
      ChatGPTModel(slug: "synthetic-luna", displayName: "Luna"),
      ChatGPTModel(slug: "synthetic-third", displayName: "Third listed"),
    ]
    XCTAssertEqual(
      AppModel.resolveChatGPTModel(catalogue, remembered: "synthetic-third"),
      "synthetic-third")
    XCTAssertEqual(
      AppModel.resolveChatGPTModel(
        [catalogue[0], catalogue[2]], remembered: "no-longer-listed"),
      "synthetic-first")
    XCTAssertEqual(
      AppModel.resolveChatGPTModel([catalogue[0], catalogue[1]], remembered: "synthetic-third"),
      "synthetic-luna")
    XCTAssertEqual(
      AppModel.resolveChatGPTModel(catalogue, remembered: "synthetic-third"),
      "synthetic-third")
    XCTAssertEqual(AppModel.resolveChatGPTModel([], remembered: "synthetic-remembered"),
      "synthetic-remembered")
    XCTAssertEqual(AppModel.resolveChatGPTModel([], remembered: nil), "")
  }

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

  func testFailedFinalCheckpointCancelsQuitAndRetryRecoversLatestDraft() throws {
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
    app.draft = "Latest in-memory draft after the last checkpoint"

    let lockPath = root.appendingPathComponent("History/.history.lock").path
    let lockFD = Darwin.open(lockPath, O_RDWR | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(lockFD, 0)
    defer { Darwin.close(lockFD) }
    XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)

    XCTAssertFalse(app.prepareForTermination())
    XCTAssertEqual(app.draft, "Latest in-memory draft after the last checkpoint")
    XCTAssertTrue(app.error?.contains("Quit was canceled") == true)
    XCTAssertFalse(app.historyAvailable)

    XCTAssertEqual(flock(lockFD, LOCK_UN), 0)
    XCTAssertTrue(app.prepareForTermination())
    XCTAssertTrue(app.historyAvailable)
    app.shutdown()

    let reopened = AppModel(
      root: root.appendingPathComponent("Models"), preferences: prefs, historySecrets: secrets,
      chatGPTSecrets: AppMemorySecrets())
    XCTAssertEqual(reopened.conversations.first?.draft,
      "Latest in-memory draft after the last checkpoint")
    reopened.shutdown()
  }

  func testWindowCloseVetoesChangedDraftOnLockAndSuccessfulRetryStopsOwnedWorkOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let suite = "LocalSwitch-test-" + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    let previousModel = SwitchAppDelegate.model
    defer {
      SwitchAppDelegate.model = previousModel
      try? FileManager.default.removeItem(at: root)
      prefs.removePersistentDomain(forName: suite)
    }
    let secrets = AppMemorySecrets()
    let app = AppModel(
      root: root.appendingPathComponent("Models"), preferences: prefs, historySecrets: secrets,
      chatGPTSecrets: AppMemorySecrets())
    SwitchAppDelegate.model = app
    app.draft = "Earlier checkpoint"
    XCTAssertTrue(app.prepareForTermination())

    // A draft can change after preflight; a contended final write must still veto close.
    app.draft = "Latest draft after preflight"
    let lockPath = root.appendingPathComponent("History/.history.lock").path
    let lockFD = Darwin.open(lockPath, O_RDWR | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(lockFD, 0)
    defer { Darwin.close(lockFD) }
    XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)
    let delegate = SwitchAppDelegate()
    XCTAssertFalse(delegate.handleWindowClose())
    XCTAssertFalse(app.didCompleteShutdownForTesting)
    XCTAssertEqual(app.draft, "Latest draft after preflight")
    XCTAssertTrue(app.error?.contains("Quit was canceled") == true)

    XCTAssertEqual(flock(lockFD, LOCK_UN), 0)
    XCTAssertTrue(delegate.handleWindowClose())
    XCTAssertTrue(app.didCompleteShutdownForTesting)
    app.draft = "Post shutdown mutation must not checkpoint"
    app.shutdown()

    let loaded = try ChatStore(root: root.appendingPathComponent("History"), secrets: secrets).load()
    XCTAssertEqual(loaded.first?.draft, "Latest draft after preflight")
  }

  func testUnvetoableFinalNotificationStopsOwnedWorkAfterFailedCheckpoint() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = AppModel(
      root: root.appendingPathComponent("Models"), historySecrets: AppMemorySecrets(),
      chatGPTSecrets: AppMemorySecrets())
    app.draft = "Keep visible until the process exits"
    let lockFD = Darwin.open(
      root.appendingPathComponent("History/.history.lock").path, O_RDWR | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(lockFD, 0)
    defer { Darwin.close(lockFD) }
    XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)

    XCTAssertFalse(app.prepareForTermination())
    XCTAssertFalse(app.didCompleteShutdownForTesting)
    XCTAssertEqual(app.draft, "Keep visible until the process exits")
    app.finishProcessTermination()
    XCTAssertTrue(app.didCompleteShutdownForTesting)
    XCTAssertEqual(app.draft, "Keep visible until the process exits")
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
