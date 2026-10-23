import Combine
import CryptoKit
import Foundation

public enum ModelStoreError: LocalizedError {
  case invalidManifest, unsafePath
  case invalidResponse(String)
  case wrongLength, checksum, invalidGGUF, diskSpace
  public var errorDescription: String? {
    switch self {
    case .invalidManifest:
      return "The model manifest is invalid. Choose a model from the bundled catalogue."
    case .unsafePath: return "The model storage path is unsafe or has been replaced."
    case .invalidResponse(let detail):
      return "The model host returned an unexpected response: \(detail)"
    case .wrongLength: return "The downloaded model has the wrong size. Retry the download."
    case .checksum:
      return
        "The model failed its SHA-256 integrity check. The damaged download was removed; retry to download a fresh copy."
    case .invalidGGUF: return "The downloaded file is not a supported GGUF model."
    case .diskSpace:
      return "There is not enough free space for this model. Free some storage and try again."
    }
  }
}

private struct InstallReceipt: Codable {
  let modelID: String
  let sha256: String
  let bytes: Int64
  let modifiedAt: Date
  let installedAt: Date
}

/// One owned transfer at a time. Installed means size/hash/header checked and atomically committed.
@MainActor public final class ModelStore: ObservableObject {
  @Published public private(set) var phase = "idle"
  @Published public private(set) var progress = 0.0
  @Published public private(set) var downloadedBytes: Int64 = 0
  @Published public private(set) var error: String?
  @Published public private(set) var activeModelID: String?
  public let root: URL
  private var generation = UUID()
  private var operation: ModelTransfer?
  private var cleanupAfterTransfer = false
  private var activeDescriptor: ModelDescriptor?
  private let configuration: URLSessionConfiguration
  private var unavailable = false

  public init(root: URL? = nil, configuration: URLSessionConfiguration = .ephemeral) throws {
    let base =
      root ?? PipAppIdentity.modelRoot()
    if FileManager.default.fileExists(atPath: base.path),
      (try base.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true
    {
      throw ModelStoreError.unsafePath
    }
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.root = base.resolvingSymlinksInPath().standardizedFileURL
    self.configuration = configuration
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 86_400
  }

  /// A readable, disabled view model when the app cannot open writable storage.
  public static func unavailableStore() -> ModelStore { ModelStore(unavailable: true) }
  private init(unavailable: Bool) {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Pip Hybrid-unavailable-" + UUID().uuidString)
    configuration = .ephemeral
    self.unavailable = unavailable
    phase = "failed"
    error = "Local storage is unavailable. No files will be downloaded or saved."
  }

  /// Receipt plus unchanged file facts. Runtime callers may additionally rehash before launch.
  public func installedURL(for model: ModelDescriptor) -> URL? {
    guard !unavailable, (try? validate(model)) != nil,
      let url = try? ownedURL(model, suffix: ".gguf"),
      let receiptURL = try? ownedURL(model, suffix: ".receipt.json"),
      let data = try? Data(contentsOf: receiptURL),
      let receipt = try? JSONDecoder().decode(InstallReceipt.self, from: data),
      receipt.modelID == model.id, receipt.sha256 == model.sha256, receipt.bytes == model.bytes,
      let facts = try? FileManager.default.attributesOfItem(atPath: url.path),
      facts[.type] as? FileAttributeType == .typeRegular,
      (facts[.size] as? NSNumber)?.int64Value == model.bytes,
      facts[.modificationDate] as? Date == receipt.modifiedAt
    else { return nil }
    return url
  }

  public func install(_ model: ModelDescriptor) async {
    guard !unavailable, operation == nil else { return }
    let token = UUID()
    generation = token
    do {
      try validate(model)
      if installedURL(for: model) != nil {
        phase = "installed"
        activeModelID = model.id
        error = nil
        progress = 1
        downloadedBytes = model.bytes
        return
      }
      let partial = try ownedURL(model, suffix: ".partial")
      let final = try ownedURL(model, suffix: ".gguf")
      let receiptURL = try ownedURL(model, suffix: ".receipt.json")
      let currentSize =
        ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?
        .int64Value ?? 0
      if currentSize > model.bytes { try FileManager.default.removeItem(at: partial) }
      let offset = Int64(currentSize > model.bytes ? 0 : currentSize)
      let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage
      if let free, free < model.bytes - offset + 64 * 1_024 * 1_024 {
        throw ModelStoreError.diskSpace
      }
      error = nil
      activeModelID = model.id
      activeDescriptor = model
      phase = "downloading"
      downloadedBytes = offset
      progress = Double(offset) / Double(model.bytes)
      cleanupAfterTransfer = false
      let worker = ModelTransfer(
        model: model, partial: partial, offset: offset, configuration: configuration
      ) { [weak self] count in
        Task { @MainActor [weak self] in
          guard let self, self.generation == token, self.phase == "downloading" else { return }
          self.downloadedBytes = count
          self.progress = Double(count) / Double(model.bytes)
        }
      }
      operation = worker
      defer {
        if operation === worker {
          operation = nil
          if cleanupAfterTransfer {
            try? FileManager.default.removeItem(at: partial)
            cleanupAfterTransfer = false
          }
        }
      }
      if offset < model.bytes { try await worker.run() }
      guard generation == token else { return }
      phase = "verifying"
      downloadedBytes = model.bytes
      progress = 1
      try await Task.detached(priority: .utility) {
        try Self.verifyFile(at: partial, model: model)
      }.value
      guard generation == token else { return }
      // Recheck owned paths immediately before mutation; never follow a replaced symlink.
      _ = try ownedURL(model, suffix: ".partial")
      _ = try ownedURL(model, suffix: ".gguf")
      _ = try ownedURL(model, suffix: ".receipt.json")
      if FileManager.default.fileExists(atPath: final.path) {
        try FileManager.default.removeItem(at: final)
      }
      try FileManager.default.moveItem(at: partial, to: final)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: final.path)
      let modified =
        try final.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        ?? Date()
      let receipt = InstallReceipt(
        modelID: model.id, sha256: model.sha256, bytes: model.bytes,
        modifiedAt: modified, installedAt: Date())
      try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
      phase = "installed"
    } catch {
      // Cancellation has its own immediate, durable visible state. Late callbacks cannot override it.
      guard generation == token else { return }
      self.error = error.localizedDescription
      phase = "failed"
      if let modelError = error as? ModelStoreError {
        switch modelError {
        case .checksum, .wrongLength, .invalidGGUF:
          if let partial = try? ownedURL(model, suffix: ".partial") {
            try? FileManager.default.removeItem(at: partial)
          }
          downloadedBytes = 0
          progress = 0
        default: break
        }
      }
    }
  }

  public func pause() {
    guard operation != nil, phase == "downloading" || phase == "verifying" else { return }
    generation = UUID()
    phase = "paused"
    operation?.cancel()
  }

  public func cancel() {
    generation = UUID()
    cleanupAfterTransfer = operation != nil
    operation?.cancel()
    if operation == nil, let model = activeDescriptor,
      let partial = try? ownedURL(model, suffix: ".partial")
    {
      try? FileManager.default.removeItem(at: partial)
    }
    phase = "idle"
    activeModelID = nil
    activeDescriptor = nil
    progress = 0
    downloadedBytes = 0
    error = nil
  }

  public func remove(_ model: ModelDescriptor) throws {
    guard !unavailable else { throw ModelStoreError.unsafePath }
    guard operation == nil else {
      throw ModelStoreError.invalidResponse("A download is still stopping. Try again shortly.")
    }
    try validate(model)
    for suffix in [".gguf", ".receipt.json", ".partial"] {
      let url = try ownedURL(model, suffix: suffix)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
    if activeModelID == model.id {
      phase = "idle"
      activeModelID = nil
      progress = 0
      downloadedBytes = 0
      error = nil
    }
  }

  /// Streaming hash + magic/version check with bounded memory. Call from a background task for large files.
  nonisolated public static func verifyFile(at url: URL, model: ModelDescriptor) throws {
    let facts = try FileManager.default.attributesOfItem(atPath: url.path)
    guard facts[.type] as? FileAttributeType == .typeRegular else {
      throw ModelStoreError.unsafePath
    }
    guard (facts[.size] as? NSNumber)?.int64Value == model.bytes else {
      throw ModelStoreError.wrongLength
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let header = try handle.read(upToCount: 8), header.count == 8,
      Array(header.prefix(4)) == [0x47, 0x47, 0x55, 0x46],
      header[4] == 3, header[5] == 0, header[6] == 0, header[7] == 0
    else { throw ModelStoreError.invalidGGUF }
    try handle.seek(toOffset: 0)
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hash.update(data: data)
    }
    let value = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard value == model.sha256 else { throw ModelStoreError.checksum }
  }

  private func validate(_ model: ModelDescriptor) throws {
    guard
      model.id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,119}$", options: .regularExpression) != nil,
      !model.id.contains(".."),
      model.bytes >= 8, model.bytes <= Int64(Int.max),
      model.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      ModelTransfer.allowed(model.downloadURL), model.downloadURL.host == "huggingface.co",
      model.downloadURL.user == nil, model.downloadURL.password == nil
    else { throw ModelStoreError.invalidManifest }
  }

  private func ownedURL(_ model: ModelDescriptor, suffix: String) throws -> URL {
    let url = root.appendingPathComponent(model.id + suffix)
    guard url.deletingLastPathComponent().standardizedFileURL == root,
      root.resolvingSymlinksInPath() == root
    else { throw ModelStoreError.unsafePath }
    if FileManager.default.fileExists(atPath: url.path),
      (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true
    {
      throw ModelStoreError.unsafePath
    }
    return url
  }
}

private final class ModelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let model: ModelDescriptor
  let partial: URL
  let configuration: URLSessionConfiguration
  let progress: @Sendable (Int64) -> Void
  var count: Int64
  var task: URLSessionDataTask?
  var session: URLSession?
  var file: FileHandle?
  var continuation: CheckedContinuation<Void, Error>?
  var problem: Error?
  var lastProgress = Date.distantPast
  let lock = NSLock()
  var cancelled = false

  init(
    model: ModelDescriptor, partial: URL, offset: Int64, configuration: URLSessionConfiguration,
    progress: @escaping @Sendable (Int64) -> Void
  ) {
    self.model = model
    self.partial = partial
    count = offset
    self.configuration = configuration
    self.progress = progress
  }

  static func allowed(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443, let host = url.host?.lowercased()
    else { return false }
    return [
      "huggingface.co", "cdn-lfs.huggingface.co", "cdn-lfs-us-1.huggingface.co",
      "cdn-lfs-eu-1.huggingface.co",
      "cas-bridge.xethub.hf.co", "cas-server.xethub.hf.co", "transfer.xethub.hf.co",
      "us.aws.cdn.hf.co",
    ].contains(host)
  }

  func run() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: model.downloadURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if count > 0 { request.setValue("bytes=\(count)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        self.task = task
        if cancelled { task.cancel() }
        task.resume()
      }
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let task = task
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, Self.allowed(url) else {
      problem = ModelStoreError.invalidResponse("Unapproved redirect destination.")
      completionHandler(nil)
      task.cancel()
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    do {
      guard let http = response as? HTTPURLResponse, let url = http.url, Self.allowed(url) else {
        throw ModelStoreError.invalidResponse("HTTPS response required.")
      }
      guard http.statusCode == 200 || http.statusCode == 206 else {
        throw ModelStoreError.invalidResponse("HTTP \(http.statusCode).")
      }
      if http.statusCode == 206 {
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
          range == "bytes \(count)-\(model.bytes - 1)/\(model.bytes)"
        else {
          throw ModelStoreError.invalidResponse(
            "The resume range does not match this pinned model.")
        }
      } else {
        // The host ignored Range. Start over; never append the full response to a partial file.
        count = 0
      }
      if response.expectedContentLength >= 0, response.expectedContentLength != model.bytes - count
      {
        throw ModelStoreError.wrongLength
      }
      if FileManager.default.fileExists(atPath: partial.path),
        (try partial.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true
      {
        throw ModelStoreError.unsafePath
      }
      if !FileManager.default.fileExists(atPath: partial.path) {
        guard
          FileManager.default.createFile(
            atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
          throw ModelStoreError.unsafePath
        }
      }
      let handle = try FileHandle(forWritingTo: partial)
      file = handle
      if count == 0 { try handle.truncate(atOffset: 0) }
      try handle.seek(toOffset: UInt64(count))
      progress(count)
      completionHandler(.allow)
    } catch {
      problem = error
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    let cancelled = cancelled
    lock.unlock()
    guard !cancelled, problem == nil else { return }
    do {
      guard Int64(data.count) <= model.bytes - count else { throw ModelStoreError.wrongLength }
      try file?.write(contentsOf: data)
      count += Int64(data.count)
      if Date().timeIntervalSince(lastProgress) >= 0.15 {
        progress(count)
        lastProgress = Date()
      }
    } catch {
      problem = error
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    do {
      try file?.synchronize()
      try file?.close()
    } catch { if problem == nil { problem = error } }
    file = nil
    lock.lock()
    let cancelled = cancelled
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    if cancelled {
      continuation?.resume(throwing: CancellationError())
    } else if let error = problem ?? error {
      continuation?.resume(throwing: error)
    } else if count != model.bytes {
      continuation?.resume(throwing: ModelStoreError.wrongLength)
    } else {
      progress(count)
      continuation?.resume()
    }
    session.finishTasksAndInvalidate()
    self.session = nil
    self.task = nil
  }
}
