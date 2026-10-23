import CryptoKit
import Darwin
import Foundation

public enum LocalRuntimeError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}

public struct RuntimeMessage: Codable, Sendable {
  public var role: String
  public var content: String
  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

private final class LoopbackSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // No redirect may move a local prompt, or its authentication, to another destination.
    completionHandler(nil)
  }
}

/// A single owned, authenticated, OS network-restricted inference child. No remote provider exists here.
@MainActor public final class LocalRuntime {
  public private(set) var state = "stopped"
  public private(set) var loadedModelID: String?
  public private(set) var processID: Int32?
  public private(set) var lastStopConfirmed = true
  private var child: Process?
  private var session: URLSession
  private var endpoint: URL?
  private var token = ""
  private var alias = ""
  private var epoch = UUID()
  private var streamTask: Task<Void, Error>?
  private var stopOperation: Task<Void, Never>?
  public static let sandboxProfile =
    "(version 1)(allow default)(deny network*)(allow network-inbound (local ip \"localhost:*\"))(allow network-outbound (remote ip \"localhost:*\"))"
  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 300
    config.urlCache = nil
    session = URLSession(
      configuration: config, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
  }
  public static func runtimeDirectory() throws -> URL {
    if let value = ProcessInfo.processInfo.environment["LOCALSWITCH_RUNTIME_DIR"] {
      return URL(fileURLWithPath: value, isDirectory: true)
    }
    if let resource = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
      FileManager.default.fileExists(atPath: resource.appendingPathComponent("llama-server").path)
    {
      return resource
    }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let development = source.appendingPathComponent(".runtime/llama-b11768")
    guard
      FileManager.default.isExecutableFile(
        atPath: development.appendingPathComponent("llama-server").path)
    else {
      throw LocalRuntimeError.message(
        "The local engine is missing. Run scripts/build-mac.sh to install the pinned runtime.")
    }
    return development
  }
  public func load(model: ModelDescriptor, file: URL) async throws {
    if loadedModelID == model.id, state == "ready", child?.isRunning == true { return }
    await stop()
    guard lastStopConfirmed else {
      throw LocalRuntimeError.message(
        "The previous engine has not stopped. Quit Pip Hybrid before loading another model.")
    }
    let generation = UUID()
    epoch = generation
    state = "loading"
    do {
      guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else {
        throw LocalRuntimeError.message(
          "The verified model file is missing. Download it again from Models.")
      }
      let directory = try Self.runtimeDirectory()
      try await Self.verifyRuntime(directory)
      try await Task.detached(priority: .utility) {
        try ModelStore.verifyFile(at: file, model: model)
      }.value
      try Task.checkCancellation()
      guard epoch == generation else { throw CancellationError() }
      let port = try Self.availablePort()
      alias = "localswitch-" + UUID().uuidString
      token = UUID().uuidString + UUID().uuidString
      endpoint = URL(string: "http://127.0.0.1:\(port)")!
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
      process.arguments = [
        "-p", Self.sandboxProfile, directory.appendingPathComponent("llama-server").path,
        "--model", file.path, "--alias", alias, "--host", "127.0.0.1", "--port", String(port),
        "--ctx-size", "4096", "--parallel", "1", "--n-predict", "512", "--threads", "4",
        "--gpu-layers", "99", "--no-webui", "--no-slots", "--offline", "--log-disable",
        "--reasoning", "off", "--no-context-shift",
      ]
      process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
        "TMPDIR": NSTemporaryDirectory(), "LLAMA_API_KEY": token,
        "GGML_METAL_PATH_RESOURCES": directory.path,
      ]
      process.qualityOfService = .utility
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      child = process
      processID = process.processIdentifier
      lastStopConfirmed = false
      let deadline = Date().addingTimeInterval(120)
      while Date() < deadline {
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard process.isRunning else {
          throw LocalRuntimeError.message(
            "The engine exited while loading (code \(process.terminationStatus)). Try the smaller model or restart Pip Hybrid."
          )
        }
        if let data = try? await request(path: "/v1/models"),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = object["data"] as? [[String: Any]],
          models.contains(where: { $0["id"] as? String == alias })
        {
          guard epoch == generation, process.isRunning else { throw CancellationError() }
          loadedModelID = model.id
          state = "ready"
          return
        }
        try await Task.sleep(nanoseconds: 150_000_000)
      }
      throw LocalRuntimeError.message("Model loading timed out. Try the smaller model.")
    } catch {
      if epoch == generation {
        await stop()
        state = error is CancellationError ? "stopped" : "failed"
      }
      throw error
    }
  }
  public func generate(
    messages: [RuntimeMessage], maxTokens: Int = 512, onDelta: @escaping @MainActor (String) -> Void
  ) async throws {
    guard state == "ready", child?.isRunning == true, let endpoint else {
      throw LocalRuntimeError.message("Load a downloaded model before sending a message.")
    }
    guard !messages.isEmpty,
      messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) }),
      messages.reduce(0, { $0 + $1.content.utf8.count }) <= 12_000
    else {
      throw LocalRuntimeError.message(
        "This conversation is too long for the 4K context. Start a new chat or shorten your message."
      )
    }
    let generation = epoch
    state = "busy"
    let body: [String: Any] = [
      "model": alias, "messages": messages.map { ["role": $0.role, "content": $0.content] },
      "stream": true, "max_tokens": max(1, min(maxTokens, 512)), "temperature": 0.5,
      "chat_template_kwargs": ["enable_thinking": false],
    ]
    var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let task = Task { @MainActor in
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
        throw LocalRuntimeError.message(
          "The engine could not accept this conversation. Start a new chat or reload the model.")
      }
      var finished = false
      for try await line in bytes.lines {
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        if line == "data: [DONE]" {
          finished = true
          break
        }
        guard line.hasPrefix("data: "), let data = String(line.dropFirst(6)).data(using: .utf8)
        else { continue }
        let delta = try Self.parseDelta(data)
        if let text = delta.text, !text.isEmpty { onDelta(text) }
        if delta.finished { finished = true }
      }
      guard finished else {
        throw LocalRuntimeError.message(
          "The local engine disconnected before finishing. Your partial answer is kept.")
      }
    }
    streamTask = task
    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard epoch == generation else { throw CancellationError() }
      state = "ready"
      streamTask = nil
    } catch {
      if epoch == generation {
        state = child?.isRunning == true ? "ready" : "failed"
        streamTask = nil
      }
      throw error
    }
  }
  public func stop() async {
    if let pending = stopOperation {
      await pending.value
      return
    }
    let stoppingEpoch = UUID()
    epoch = stoppingEpoch
    streamTask?.cancel()
    streamTask = nil
    state = "stopping"
    let owned = child
    let pending = Task { @MainActor in
      if let owned, owned.isRunning {
        owned.terminate()
        for _ in 0..<40 {
          if !owned.isRunning { break }
          try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if owned.isRunning { Darwin.kill(owned.processIdentifier, SIGKILL) }
        for _ in 0..<40 {
          if !owned.isRunning { break }
          try? await Task.sleep(nanoseconds: 50_000_000)
        }
      }
      // A stale Stop must never discard ownership of a newer child.
      guard self.epoch == stoppingEpoch, self.child === owned else { return }
      self.lastStopConfirmed = owned?.isRunning != true
      if self.lastStopConfirmed {
        self.child = nil
        self.processID = nil
        self.loadedModelID = nil
        self.endpoint = nil
        self.token = ""
        self.state = "stopped"
      } else {
        self.state = "stop-unconfirmed"
      }
    }
    stopOperation = pending
    await pending.value
    stopOperation = nil
  }
  /// For application termination. Only the child owned by this instance is signalled.
  public func terminateImmediately() {
    streamTask?.cancel()
    if let child, child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
  }
  public func authorizationProbe() async throws -> Int {
    guard let endpoint else { throw LocalRuntimeError.message("No engine is loaded.") }
    let (_, response) = try await session.data(from: endpoint.appendingPathComponent("v1/models"))
    return (response as? HTTPURLResponse)?.statusCode ?? 0
  }
  private func request(path: String) async throws -> Data {
    guard let endpoint else { throw LocalRuntimeError.message("No engine endpoint.") }
    var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw LocalRuntimeError.message("Engine not ready.")
    }
    return data
  }
  public static func parseDelta(_ data: Data) throws -> (text: String?, finished: Bool) {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let object, object["error"] == nil, let choices = object["choices"] as? [[String: Any]]
    else { throw LocalRuntimeError.message("The local engine returned an invalid stream.") }
    guard let first = choices.first else { return (nil, false) }
    if let reason = first["finish_reason"] as? String, reason != "stop" {
      throw LocalRuntimeError.message(
        reason == "length"
          ? "The answer reached the local output limit. Your partial answer is kept; ask Pip to continue."
          : "The engine ended the answer unexpectedly (\(reason)). Your partial answer is kept.")
    }
    return (
      (first["delta"] as? [String: Any])?["content"] as? String, first["finish_reason"] is String
    )
  }
  private static func availablePort() throws -> UInt16 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LocalRuntimeError.message("Could not reserve a local engine port.") }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      throw LocalRuntimeError.message("Could not bind a local engine port.")
    }
    var count = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &count) }
    }
    guard named == 0 else {
      throw LocalRuntimeError.message("Could not inspect a local engine port.")
    }
    return UInt16(bigEndian: address.sin_port)
  }
  nonisolated private static func verifyRuntime(_ directory: URL) async throws {
    try await Task.detached(priority: .utility) {
      let manifest = directory.appendingPathComponent("localswitch-runtime.json")
      guard let data = try? Data(contentsOf: manifest),
        let files = try JSONSerialization.jsonObject(with: data) as? [String: String],
        !files.isEmpty, files["llama-server"] != nil
      else {
        throw LocalRuntimeError.message(
          "The engine integrity manifest is missing. Rebuild Pip Hybrid.")
      }
      for (name, digest) in files {
        try Task.checkCancellation()
        guard !name.contains("/"), !name.contains("..") else {
          throw LocalRuntimeError.message("Invalid runtime manifest.")
        }
        let path = directory.appendingPathComponent(name)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
          hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
          throw LocalRuntimeError.message(
            "Local engine integrity check failed. Rebuild Pip Hybrid before loading a model.")
        }
      }
    }.value
  }
}
