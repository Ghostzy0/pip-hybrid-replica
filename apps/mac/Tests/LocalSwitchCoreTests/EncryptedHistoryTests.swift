import CryptoKit
import Darwin
import Foundation
import Security
import XCTest

@testable import LocalSwitchCore

final class HistoryTestSecrets: SecretStore {
  var values: [String: Data] = [:]
  var failure: Error?
  var writes = 0
  var writeFailure: Error?
  var corruptWrites = false
  func read(_ key: String) throws -> Data? {
    if let failure { throw failure }
    return values[key]
  }
  func write(_ data: Data, for key: String) throws {
    if let failure { throw failure }
    if let writeFailure { throw writeFailure }
    writes += 1
    values[key] = corruptWrites ? Data(repeating: 0x5a, count: data.count) : data
  }
  func remove(_ key: String) throws {
    if let failure { throw failure }
    values.removeValue(forKey: key)
  }
}

final class EncryptedHistoryTests: XCTestCase {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "LocalSwitch-encryption-test-" + UUID().uuidString
    ).resolvingSymlinksInPath()
  }
  private func chats() -> [SavedConversation] {
    [
      SavedConversation(
        id: UUID(),
        messages: [
          ChatMessage(role: "user", content: "Synthetic private marker: violet elephant 812693"),
          ChatMessage(role: "assistant", content: "Partial 👋🏽", state: "streaming"),
        ], draft: "Unsent confidential synthetic draft")
    ]
  }
  func testAuthenticatedRoundTripEncryptsTitlesDraftsAndMessagesWithPrivatePermissions() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = HistoryTestSecrets()
    let store = try ChatStore(root: root, secrets: secrets)
    XCTAssertTrue(try store.load().isEmpty)
    let input = chats()
    try store.save(input)
    let ciphertext = try Data(contentsOf: store.file)
    for value in [input[0].title, input[0].draft!, input[0].messages[0].content] {
      XCTAssertNil(ciphertext.range(of: Data(value.utf8)))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations.json").path)
    )
    let reopened = try ChatStore(root: root, secrets: secrets)
    let output = try reopened.load()
    XCTAssertEqual(output[0].id, input[0].id)
    XCTAssertEqual(output[0].draft, input[0].draft)
    XCTAssertEqual(output[0].messages[1].content, "Partial 👋🏽")
    XCTAssertEqual(output[0].messages[1].state, "interrupted")
    let attrs = try FileManager.default.attributesOfItem(atPath: store.file.path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }
  func testFreshNonceForEverySave() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChatStore(root: root, secrets: HistoryTestSecrets())
    let input = chats()
    try store.save(input)
    let first = try Data(contentsOf: store.file)
    try store.save(input)
    let second = try Data(contentsOf: store.file)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try store.load().first?.id, input.first?.id)
  }
  func testMissingKeyNeverRegeneratesOrOverwritesExistingCiphertext() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = HistoryTestSecrets()
    let store = try ChatStore(root: root, secrets: secrets)
    try store.save(chats())
    let original = try Data(contentsOf: store.file)
    secrets.values.removeAll()
    let writes = secrets.writes
    XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
    XCTAssertThrowsError(try store.save([]))
    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(secrets.writes, writes)
    XCTAssertTrue(secrets.values.isEmpty)
    XCTAssertEqual(try Data(contentsOf: store.file), original)
  }
  func testWrongKeyAndTamperedCiphertextFailClosed() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = HistoryTestSecrets()
    let store = try ChatStore(root: root, secrets: secrets)
    try store.save(chats())
    let original = try Data(contentsOf: store.file)
    let actualKey = secrets.values[store.keyIdentifier]!
    secrets.values[store.keyIdentifier] = Data(repeating: 0x88, count: 32)
    XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
    XCTAssertThrowsError(try store.save([]))
    XCTAssertEqual(try Data(contentsOf: store.file), original)
    secrets.values[store.keyIdentifier] = actualKey
    var modified = original
    modified[modified.count - 1] ^= 0x80
    try modified.write(to: store.file)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.save([]))
    XCTAssertEqual(try Data(contentsOf: store.file), modified)
  }
  func testHeaderVersionAndTruncationRejectWithoutReplacement() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = HistoryTestSecrets()
    let store = try ChatStore(root: root, secrets: secrets)
    try store.save(chats())
    let original = try Data(contentsOf: store.file)
    for modified in [
      Data([0x4c, 0x53, 0x48, 0x45, 2]) + original.dropFirst(5), Data(original.prefix(20)),
    ] {
      try modified.write(to: store.file)
      XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
      XCTAssertThrowsError(try store.save([]))
      XCTAssertEqual(try Data(contentsOf: store.file), modified)
    }
  }
  func testLegacyMigrationAuthenticatesBeforeRemovingPlaintext() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = chats()
    let legacy = root.appendingPathComponent("conversations.json")
    try JSONEncoder().encode(input).write(to: legacy)
    let secrets = HistoryTestSecrets()
    let store = try ChatStore(root: root, secrets: secrets)
    XCTAssertTrue(store.migratedLegacy)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertEqual(try store.load().first?.id, input[0].id)
    XCTAssertFalse(try ChatStore(root: root, secrets: secrets).migratedLegacy)
  }
  func testInterruptedMigrationFinishesOnlyWhenBothHistoriesMatch() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = HistoryTestSecrets()
    let store = try ChatStore(root: root, secrets: secrets)
    let input = chats()
    try store.save(input)
    let legacy = root.appendingPathComponent("conversations.json")
    try JSONEncoder().encode(input).write(to: legacy)
    XCTAssertTrue(try ChatStore(root: root, secrets: secrets).migratedLegacy)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    let other = try JSONEncoder().encode(chats())
    try other.write(to: legacy)
    let original = try Data(contentsOf: store.file)
    XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
    XCTAssertEqual(try Data(contentsOf: legacy), other)
    XCTAssertEqual(try Data(contentsOf: store.file), original)
  }
  func testUnavailableKeychainAndMalformedLegacyPreserveOriginal() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacy = root.appendingPathComponent("conversations.json")
    let original = try JSONEncoder().encode(chats())
    try original.write(to: legacy)
    let secrets = HistoryTestSecrets()
    secrets.failure = SecretStoreError(status: errSecInteractionNotAllowed)
    XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
    XCTAssertEqual(try Data(contentsOf: legacy), original)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations.lshe").path)
    )
    secrets.failure = nil
    try Data("not-json".utf8).write(to: legacy)
    XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
    XCTAssertEqual(secrets.writes, 0)
    XCTAssertEqual(try String(contentsOf: legacy), "not-json")
  }
  func testStaleWriterCannotClobberAnotherInstance() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = HistoryTestSecrets()
    let input = chats()
    let first = try ChatStore(root: root, secrets: secrets)
    let second = try ChatStore(root: root, secrets: secrets)
    try first.save(input)
    let original = try Data(contentsOf: first.file)
    XCTAssertThrowsError(try second.save([]))
    XCTAssertEqual(try Data(contentsOf: first.file), original)
    _ = try second.load()
    try second.save([])
    XCTAssertThrowsError(try first.save(input))
    XCTAssertTrue(try first.load().isEmpty)
  }
  func testOwnedPathsRejectLegacyAndCipherSymlinks() throws {
    let root = root()
    let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let store = try ChatStore(root: root, secrets: HistoryTestSecrets())
    try Data("Outside remains".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: outside)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.save([]))
    XCTAssertEqual(try String(contentsOf: outside), "Outside remains")
  }
  func testOversizedLegacyAndInvalidKeyAreRejected() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = HistoryTestSecrets()
    let store = try ChatStore(root: root, secrets: secrets)
    try store.save([])
    let legacy = root.appendingPathComponent("conversations.json")
    try Data(repeating: 0x20, count: 20_000_001).write(to: legacy)
    XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
    try FileManager.default.removeItem(at: legacy)
    secrets.values[store.keyIdentifier] = Data(repeating: 0, count: 31)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.save([]))
  }
  func testFailedKeyPersistencePreservesLegacyAndNeverWritesCiphertext() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacy = root.appendingPathComponent("conversations.json")
    let original = try JSONEncoder().encode(chats())
    try original.write(to: legacy)
    let secrets = HistoryTestSecrets()
    secrets.writeFailure = SecretStoreError(status: errSecNotAvailable)
    XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
    XCTAssertEqual(try Data(contentsOf: legacy), original)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations.lshe").path)
    )
    secrets.writeFailure = nil
    secrets.corruptWrites = true
    XCTAssertThrowsError(try ChatStore(root: root, secrets: secrets))
    XCTAssertEqual(try Data(contentsOf: legacy), original)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations.lshe").path)
    )
  }
  func testBusyLockFailsPromptlyWithoutChangingHistory() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChatStore(root: root, secrets: HistoryTestSecrets())
    try store.save(chats())
    let original = try Data(contentsOf: store.file)
    let fd = Darwin.open(root.appendingPathComponent(".history.lock").path, O_RDWR)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer {
      _ = flock(fd, LOCK_UN)
      Darwin.close(fd)
    }
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    let started = Date()
    XCTAssertThrowsError(try store.save([]))
    XCTAssertThrowsError(try store.load())
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    XCTAssertEqual(try Data(contentsOf: store.file), original)
  }

}
