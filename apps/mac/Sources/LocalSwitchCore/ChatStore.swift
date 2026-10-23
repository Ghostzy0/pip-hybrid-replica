import CryptoKit
import Darwin
import Foundation

public struct ChatMessage: Identifiable, Codable, Sendable {
  public var id: UUID
  public var role: String
  public var content: String
  public var state: String
  public var createdAt: Date
  public var route: String?
  public var model: String?
  public var outboundDigest: String?
  public var redactedForCloud: Bool?
  public init(
    id: UUID = UUID(), role: String, content: String, state: String = "complete",
    createdAt: Date = Date(), route: String? = nil, model: String? = nil,
    outboundDigest: String? = nil, redactedForCloud: Bool? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.state = state
    self.createdAt = createdAt
    self.route = route
    self.model = model
    self.outboundDigest = outboundDigest
    self.redactedForCloud = redactedForCloud
  }
}
public struct SavedConversation: Identifiable, Codable, Sendable {
  public var id: UUID
  public var title: String
  public var messages: [ChatMessage]
  public var updatedAt: Date
  public var draft: String?
  public init(id: UUID, messages: [ChatMessage], updatedAt: Date = Date(), draft: String? = nil) {
    self.id = id
    self.messages = messages
    self.updatedAt = updatedAt
    self.draft = draft
    title = String(
      (messages.first(where: { $0.role == "user" })?.content ?? draft ?? "New chat").prefix(70))
  }
}
public enum ChatStoreError: LocalizedError {
  case missingKey, invalidKey, unsupportedFormat, authenticationFailed, unsafePath, tooLarge
  case conflict, busy, migrationConflict, io
  public var errorDescription: String? {
    switch self {
    case .missingKey:
      return
        "The encryption key for this history is missing from your Mac Keychain. Existing history is preserved; do not reset the key."
    case .invalidKey: return "The history encryption key is invalid. Existing history is preserved."
    case .unsupportedFormat:
      return
        "This encrypted history format is not supported by this build. Existing history is preserved."
    case .authenticationFailed:
      return
        "This history could not be authenticated or decrypted. The key may not match, or the file may be damaged. Existing history is preserved."
    case .unsafePath:
      return "The history path is unsafe or has been replaced. No history was written."
    case .tooLarge:
      return
        "Local history exceeds its safe size. Existing files are preserved. Delete older chats after opening a valid history."
    case .conflict:
      return
        "History changed in another app instance. Reload it before saving; the newer file was preserved."
    case .busy: return "Another app instance is accessing history. Try again shortly."
    case .migrationConflict:
      return
        "Both old and encrypted histories exist with different contents. Both were preserved for recovery."
    case .io:
      return "The encrypted history could not be read or saved. Existing files are preserved."
    }
  }
}

/// AES-256-GCM history with a separately protected Keychain key. No plaintext fallback.
/// A nonblocking file lock serialises cooperating writers/migration; snapshot hashes reject stale saves.
public struct ChatStore {
  public let file: URL
  public private(set) var migratedLegacy: Bool
  public let encryptionDescription = "AES-256-GCM · key in your Mac login Keychain"
  public let keyIdentifier: String
  private let root: URL
  private let legacy: URL
  private let secrets: any SecretStore
  private let state: Snapshot
  private static let header = Data([0x4c, 0x53, 0x48, 0x45, 1])
  private static let maxPlaintext = 20_000_000
  private static let maxEncrypted = maxPlaintext + 33
  private final class Snapshot {
    var digest: Data?
    init(_ digest: Data? = nil) { self.digest = digest }
  }

  public init(
    root: URL,
    secrets: any SecretStore = KeychainSecretStore(service: PipAppIdentity.historyService)
  ) throws {
    let base = root.standardizedFileURL
    guard base.isFileURL, base.resolvingSymlinksInPath().path == base.path else {
      throw ChatStoreError.unsafePath
    }
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    self.root = base
    file = base.appendingPathComponent("conversations.lshe")
    legacy = base.appendingPathComponent("conversations.json")
    keyIdentifier =
      "history-v1-"
      + SHA256.hash(data: Data(base.path.utf8)).map { String(format: "%02x", $0) }.joined()
    self.secrets = secrets
    state = Snapshot()
    // Use a fully initialised local value so no migration writes precede path/key checks.
    migratedLegacy = false
    let result = try withLock { try prepare() }
    state.digest = result.digest
    migratedLegacy = result.migrated
  }
  private func prepare() throws -> (digest: Data?, migrated: Bool) {
    try validatePaths()
    let encrypted = try readIfPresent(file, limit: Self.maxEncrypted)
    let old = try readIfPresent(legacy, limit: Self.maxPlaintext)
    let rawKey = try secrets.read(keyIdentifier)
    if encrypted != nil && rawKey == nil { throw ChatStoreError.missingKey }
    let existingKey = try rawKey.map { try key(from: $0) }
    // Decode legacy before creating a key or touching either file.
    let oldChats = try old.map { try decode($0) }
    let oldCanonical = try oldChats.map { try encode($0) }
    if let encrypted {
      guard let existingKey else { throw ChatStoreError.missingKey }
      let plaintext = try decrypt(encrypted, key: existingKey)
      _ = try decode(plaintext)
      if let oldCanonical {
        guard plaintext == oldCanonical else { throw ChatStoreError.migrationConflict }
        try removeLegacy(expected: old!)
        return (digest(encrypted), true)
      }
      return (digest(encrypted), false)
    }
    let usableKey: SymmetricKey
    if let existingKey {
      usableKey = existingKey
    } else {
      let generated = SymmetricKey(size: .bits256)
      let bytes = generated.withUnsafeBytes { Data($0) }
      try secrets.write(bytes, for: keyIdentifier)
      guard try secrets.read(keyIdentifier) == bytes else { throw ChatStoreError.missingKey }
      usableKey = generated
    }
    if let oldCanonical {
      let sealed = try encrypt(oldCanonical, key: usableKey)
      try atomicWrite(sealed)
      // Read the committed bytes, authenticate and decode BEFORE deleting the old plaintext.
      guard let committed = try readIfPresent(file, limit: Self.maxEncrypted),
        try decrypt(committed, key: usableKey) == oldCanonical
      else { throw ChatStoreError.authenticationFailed }
      _ = try decode(oldCanonical)
      try removeLegacy(expected: old!)
      return (digest(committed), true)
    }
    return (nil, false)
  }
  public func load() throws -> [SavedConversation] {
    try withLock {
      try validatePaths()
      guard let encrypted = try readIfPresent(file, limit: Self.maxEncrypted) else {
        guard state.digest == nil else { throw ChatStoreError.conflict }
        return []
      }
      let key = try currentKey()
      var chats = try decode(decrypt(encrypted, key: key))
      state.digest = digest(encrypted)
      for i in chats.indices {
        for j in chats[i].messages.indices where chats[i].messages[j].state == "streaming" {
          chats[i].messages[j].state = "interrupted"
        }
      }
      return chats.sorted { $0.updatedAt > $1.updatedAt }
    }
  }
  public func save(_ conversations: [SavedConversation]) throws {
    try withLock {
      try validatePaths()
      let key = try currentKey()
      let current = try readIfPresent(file, limit: Self.maxEncrypted)
      if let current { _ = try decode(decrypt(current, key: key)) }
      guard current.map(digest) == state.digest else { throw ChatStoreError.conflict }
      // Never silently bypass a leftover legacy file that needs an explicit recovery/migration.
      guard try readIfPresent(legacy, limit: Self.maxPlaintext) == nil else {
        throw ChatStoreError.migrationConflict
      }
      let plaintext = try encode(conversations)
      let encrypted = try encrypt(plaintext, key: key)
      try atomicWrite(encrypted)
      state.digest = digest(encrypted)
    }
  }
  private func currentKey() throws -> SymmetricKey {
    guard let data = try secrets.read(keyIdentifier) else { throw ChatStoreError.missingKey }
    return try key(from: data)
  }
  private func key(from data: Data) throws -> SymmetricKey {
    guard data.count == 32 else { throw ChatStoreError.invalidKey }
    return SymmetricKey(data: data)
  }
  private func encode(_ conversations: [SavedConversation]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(conversations)
    guard data.count <= Self.maxPlaintext else { throw ChatStoreError.tooLarge }
    return data
  }
  private func decode(_ data: Data) throws -> [SavedConversation] {
    guard data.count <= Self.maxPlaintext else { throw ChatStoreError.tooLarge }
    return try JSONDecoder().decode([SavedConversation].self, from: data)
  }
  private func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
  private func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
    guard let sealed = try AES.GCM.seal(data, using: key, authenticating: Self.header).combined
    else { throw ChatStoreError.authenticationFailed }
    return Self.header + sealed
  }
  private func decrypt(_ data: Data, key: SymmetricKey) throws -> Data {
    guard data.count >= Self.header.count + 28, data.prefix(Self.header.count) == Self.header else {
      throw ChatStoreError.unsupportedFormat
    }
    do {
      return try AES.GCM.open(
        AES.GCM.SealedBox(combined: Data(data.dropFirst(Self.header.count))), using: key,
        authenticating: Self.header)
    } catch { throw ChatStoreError.authenticationFailed }
  }
  private func validatePaths() throws {
    guard root.resolvingSymlinksInPath().path == root.path else { throw ChatStoreError.unsafePath }
    for url in [file, legacy] {
      guard url.deletingLastPathComponent().path == root.path else {
        throw ChatStoreError.unsafePath
      }
      if let facts = try? FileManager.default.attributesOfItem(atPath: url.path),
        facts[.type] as? FileAttributeType != .typeRegular
      {
        throw ChatStoreError.unsafePath
      }
    }
  }
  private func readIfPresent(_ url: URL, limit: Int) throws -> Data? {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw ChatStoreError.unsafePath
    }
    defer { Darwin.close(fd) }
    var facts = stat()
    guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_nlink == 1 else {
      throw ChatStoreError.unsafePath
    }
    guard facts.st_size >= 0, facts.st_size <= limit else { throw ChatStoreError.tooLarge }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw ChatStoreError.io
      }
      if count == 0 { break }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= limit else { throw ChatStoreError.tooLarge }
    }
    return result
  }
  private func atomicWrite(_ data: Data) throws {
    try validatePaths()
    let temp = root.appendingPathComponent(".history-" + UUID().uuidString + ".tmp")
    let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ChatStoreError.io }
    defer {
      Darwin.close(fd)
      try? FileManager.default.removeItem(at: temp)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(
          fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw ChatStoreError.io }
        offset += written
      }
    }
    guard fsync(fd) == 0 else { throw ChatStoreError.io }
    try validatePaths()
    guard Darwin.rename(temp.path, file.path) == 0 else { throw ChatStoreError.io }
    let dir = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if dir >= 0 {
      _ = fsync(dir)
      Darwin.close(dir)
    }
  }
  private func removeLegacy(expected: Data) throws {
    guard try readIfPresent(legacy, limit: Self.maxPlaintext) == expected else {
      throw ChatStoreError.migrationConflict
    }
    try validatePaths()
    guard Darwin.unlink(legacy.path) == 0 else { throw ChatStoreError.io }
  }
  private func withLock<T>(_ action: () throws -> T) throws -> T {
    try validatePaths()
    let path = root.appendingPathComponent(".history.lock")
    let fd = Darwin.open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ChatStoreError.unsafePath }
    defer { Darwin.close(fd) }
    var facts = stat()
    guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_nlink == 1 else {
      throw ChatStoreError.unsafePath
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ChatStoreError.busy }
    defer { _ = flock(fd, LOCK_UN) }
    return try action()
  }
}
