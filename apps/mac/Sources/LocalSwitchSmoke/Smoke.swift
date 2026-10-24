import Foundation
import LocalSwitchCore
import Darwin

@main struct Smoke {
  @MainActor static func main() async {
    do {
      let device = DeviceSnapshot.inspect()
      print("HARDWARE " + String(data: try JSONEncoder().encode(device), encoding: .utf8)!)
      if CommandLine.arguments.contains("--isolated-acceptance") {
        try await runIsolatedAcceptance()
        return
      }
      guard
        CommandLine.arguments.contains("--acceptance")
          || CommandLine.arguments.contains("--download")
      else { return }
      let models = try ModelStore()
      let modelID: String
      if let index = CommandLine.arguments.firstIndex(of: "--model"),
        CommandLine.arguments.indices.contains(index + 1)
      {
        modelID = CommandLine.arguments[index + 1]
      } else {
        modelID = "qwen3-0.6b-q8_0"
      }
      guard let model = ModelDescriptor.catalogue.first(where: { $0.id == modelID }) else {
        throw LocalRuntimeError.message("Unknown catalogue model")
      }
      print("MODEL \(model.id) expectedBytes=\(model.bytes) fits=\(model.fits(device))")
      if models.installedURL(for: model) == nil {
        let progress = Task { @MainActor in
          while !Task.isCancelled {
            print("DOWNLOAD \(models.phase) \(models.downloadedBytes)/\(model.bytes)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
          }
        }
        await models.install(model)
        progress.cancel()
      }
      guard let file = models.installedURL(for: model) else {
        throw LocalRuntimeError.message("Download failed: \(models.error ?? models.phase)")
      }
      print("VERIFIED \(file.lastPathComponent)")
      guard CommandLine.arguments.contains("--acceptance") else { return }
      let runtime = LocalRuntime()
      do {
        let start = Date()
        try await runtime.load(model: model, file: file)
        print(
          "LOADED \(runtime.state) pid=\(runtime.processID ?? 0) seconds=\(Date().timeIntervalSince(start))"
        )
        let unauthorized = try await runtime.authorizationProbe()
        guard unauthorized == 401 else {
          throw LocalRuntimeError.message(
            "Unauthenticated engine request was not rejected: \(unauthorized)")
        }
        print("AUTH rejected=\(unauthorized)")
        var answer = ""
        try await runtime.generate(
          messages: [
            RuntimeMessage(
              role: "system",
              content:
                "You are Pip. You run on this computer using a local language model, with no internet or tools. Be concise and honest."
            ),
            RuntimeMessage(
              role: "user",
              content: "Say hello, then tell me where you are running. Keep it to one sentence."),
          ], maxTokens: 80
        ) { text in answer += text }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw LocalRuntimeError.message("Empty local response")
        }
        print("ANSWER " + answer.replacingOccurrences(of: "\n", with: " "))
        var partial = ""
        let run = Task { @MainActor in
          try await runtime.generate(
            messages: [
              RuntimeMessage(
                role: "user",
                content:
                  "Write a very long numbered list of useful ideas for a local private AI app. Keep going for 400 words."
              )
            ], maxTokens: 512
          ) { text in partial += text }
        }
        for _ in 0..<100 {
          if !partial.isEmpty { break }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        let stopStart = Date()
        async let stop1: Void = runtime.stop()
        async let stop2: Void = runtime.stop()
        _ = await (stop1, stop2)
        run.cancel()
        _ = await run.result
        let stopped = partial
        try await Task.sleep(nanoseconds: 300_000_000)
        guard runtime.lastStopConfirmed, runtime.processID == nil, partial == stopped,
          !partial.isEmpty
        else { throw LocalRuntimeError.message("Stop acceptance failed") }
        print(
          "STOP confirmed=true lateTokens=false seconds=\(Date().timeIntervalSince(stopStart)) partialCharacters=\(partial.count)"
        )
        try await runtime.load(model: model, file: file)
        print("RELOAD \(runtime.state)")
        await runtime.stop()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
          "Pip Hybrid-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try ChatStore(root: root, secrets: SmokeSecrets())
        try history.save([
          SavedConversation(
            id: UUID(),
            messages: [
              ChatMessage(role: "user", content: "Synthetic local test"),
              ChatMessage(role: "assistant", content: answer),
            ])
        ])
        guard try history.load().first?.messages.last?.content == answer else {
          throw LocalRuntimeError.message("History reload failed")
        }
        print("HISTORY persisted-and-reloaded=true")
        print("ACCEPTANCE PASS")
      } catch {
        await runtime.stop()
        throw error
      }
    } catch {
      fputs("FAIL \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}

@MainActor private func runIsolatedAcceptance() async throws {
  let args = CommandLine.arguments
  func value(after option: String) throws -> String? {
    guard let index = args.firstIndex(of: option) else { return nil }
    guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
      throw LocalRuntimeError.message("Missing value for \(option)")
    }
    return args[index + 1]
  }
  guard let rootValue = try value(after: "--model-root") else {
    throw LocalRuntimeError.message("--isolated-acceptance requires --model-root")
  }
  let rootURL = try ownedSyntheticRoot(rootValue)
  guard args.contains("--no-download") else {
    throw LocalRuntimeError.message("Isolated acceptance requires explicit --no-download")
  }
  let modelID: String
  if let supplied = try value(after: "--model") { modelID = supplied }
  else { modelID = "qwen3-0.6b-q8_0" }
  guard let model = ModelDescriptor.catalogue.first(where: { $0.id == modelID }) else {
    throw LocalRuntimeError.message("Unknown catalogue model")
  }
  try requireSafePath(rootURL.appendingPathComponent(model.id + ".gguf"), type: S_IFREG, label: "model file")
  try requireSafePath(rootURL.appendingPathComponent(model.id + ".receipt.json"), type: S_IFREG, label: "model receipt")
  try validateRuntimePaths()
  let models = try ModelStore(root: rootURL)
  guard let file = models.installedURL(for: model) else {
    throw LocalRuntimeError.message("Model is missing or unverified in isolated root; downloads are disabled")
  }
  print("MODEL \(model.id) expectedBytes=\(model.bytes) sha256=\(model.sha256) fits=\(model.fits(DeviceSnapshot.inspect()))")
  print("MODEL_FILE \(file.lastPathComponent)")
  let runtime = LocalRuntime()
  do {
    let loadStart = ProcessInfo.processInfo.systemUptime
    try await runtime.load(model: model, file: file)
    print("LOADED \(runtime.state) pid=\(runtime.processID ?? 0) seconds=\(ProcessInfo.processInfo.systemUptime - loadStart)")
    var answer = ""
    let generationStart = ProcessInfo.processInfo.systemUptime
    try await runtime.generate(messages: [
      RuntimeMessage(role: "system", content: "You are Pip. Answer briefly. This is a synthetic local acceptance prompt."),
      RuntimeMessage(role: "user", content: "Reply with a short greeting and say you are running locally.")
    ], maxTokens: 48) { delta in
      if answer.isEmpty { print("FIRST_TEXT seconds=\(ProcessInfo.processInfo.systemUptime - generationStart)") }
      answer += delta
    }
    guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LocalRuntimeError.message("Empty local response")
    }
    print("ANSWER " + answer.replacingOccurrences(of: "\n", with: " "))
    var partial = ""
    let run = Task { @MainActor in
      try await runtime.generate(messages: [RuntimeMessage(role: "user", content: "Write a long numbered list of ordinary ways to organize a desk. Keep going." )], maxTokens: 512) { partial += $0 }
    }
    for _ in 0..<100 where partial.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
    guard !partial.isEmpty else { throw LocalRuntimeError.message("No partial output was available for Stop acceptance") }
    let stopStart = ProcessInfo.processInfo.systemUptime
    await runtime.stop()
    let stopped = partial
    run.cancel()
    _ = await run.result
    try await Task.sleep(nanoseconds: 300_000_000)
    guard runtime.lastStopConfirmed, runtime.processID == nil, partial == stopped else {
      throw LocalRuntimeError.message("Stop acceptance failed")
    }
    print("STOP confirmed=true lateTokens=false seconds=\(ProcessInfo.processInfo.systemUptime - stopStart) partialCharacters=\(partial.count)")
    let reloadStart = ProcessInfo.processInfo.systemUptime
    try await runtime.load(model: model, file: file)
    print("RELOAD state=\(runtime.state) seconds=\(ProcessInfo.processInfo.systemUptime - reloadStart)")
    await runtime.stop()
    print("ISOLATED_ACCEPTANCE PASS")
  } catch {
    await runtime.stop()
    throw error
  }
}

private func validatedDirectory(_ path: String, label: String) throws -> URL {
  guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
    throw LocalRuntimeError.message("\(label) path must be absolute and contain no '..'")
  }
  let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  try requireSafePath(url, type: S_IFDIR, label: label)
  return url
}

private func requireSafePath(_ url: URL, type: mode_t, label: String) throws {
  let path = url.standardizedFileURL.path
  var current = ""
  for component in path.split(separator: "/") {
    current += "/" + component
    var facts = stat()
    let result = current.withCString { Darwin.lstat($0, &facts) }
    guard result == 0, (facts.st_mode & S_IFMT) != S_IFLNK else {
      throw LocalRuntimeError.message("\(label) path has a missing or symlink component")
    }
    if current == path, (facts.st_mode & S_IFMT) != type {
      throw LocalRuntimeError.message("\(label) has an unexpected file type")
    }
  }
}

@MainActor private func validateRuntimePaths() throws {
  let directory = try LocalRuntime.runtimeDirectory()
  try requireSafePath(directory, type: S_IFDIR, label: "runtime directory")
  let manifestURL = directory.appendingPathComponent("localswitch-runtime.json")
  try requireSafePath(manifestURL, type: S_IFREG, label: "runtime manifest")
  let data = try Data(contentsOf: manifestURL)
  guard let files = try JSONSerialization.jsonObject(with: data) as? [String: String],
    !files.isEmpty, files["llama-server"] != nil
  else { throw LocalRuntimeError.message("Runtime manifest is missing or invalid") }
  for name in files.keys {
    guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
      throw LocalRuntimeError.message("Runtime manifest contains an unsafe path")
    }
    try requireRuntimeAsset(directory: directory, name: name)
  }
}

private func requireRuntimeAsset(directory: URL, name: String) throws {
  let root = directory.standardizedFileURL.path
  var current = directory.appendingPathComponent(name).standardizedFileURL
  var visited = Set<String>()
  for _ in 0..<16 {
    let path = current.path
    guard path.hasPrefix(root + "/"), !visited.contains(path) else {
      throw LocalRuntimeError.message("Runtime asset symlink escapes or cycles")
    }
    visited.insert(path)
    let relative = String(path.dropFirst(root.count + 1))
    let components = relative.split(separator: "/")
    guard !components.isEmpty else {
      throw LocalRuntimeError.message("Runtime asset path is invalid")
    }
    var parent = directory
    for component in components.dropLast() {
      parent.appendPathComponent(String(component), isDirectory: true)
      try requireSafePath(parent, type: S_IFDIR, label: "runtime asset parent")
    }
    var facts = stat()
    guard path.withCString({ Darwin.lstat($0, &facts) }) == 0 else {
      throw LocalRuntimeError.message("Runtime asset is missing")
    }
    let fileType = facts.st_mode & S_IFMT
    if fileType == S_IFREG { return }
    guard fileType == S_IFLNK else {
      throw LocalRuntimeError.message("Runtime asset is not a regular file or leaf alias")
    }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = path.withCString { pointer in
      buffer.withUnsafeMutableBufferPointer { bytes in
        Darwin.readlink(pointer, bytes.baseAddress!, bytes.count)
      }
    }
    guard count > 0, let target = String(bytes: buffer.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
      throw LocalRuntimeError.message("Runtime asset symlink target is invalid")
    }
    current = (target.hasPrefix("/")
      ? URL(fileURLWithPath: target)
      : current.deletingLastPathComponent().appendingPathComponent(target)
    ).standardizedFileURL
  }
  throw LocalRuntimeError.message("Runtime asset symlink chain exceeds limit")
}

private func ownedSyntheticRoot(_ path: String) throws -> URL {
  let url = try validatedDirectory(path, label: "model root")
  var facts = stat()
  guard url.path.withCString({ Darwin.lstat($0, &facts) }) == 0,
    (facts.st_mode & S_IFMT) == S_IFDIR, facts.st_uid == getuid()
  else {
    throw LocalRuntimeError.message("Model root must be owned by the current user")
  }
  return url
}

private final class SmokeSecrets: SecretStore {
  private var values: [String: Data] = [:]
  func read(_ key: String) throws -> Data? { values[key] }
  func write(_ data: Data, for key: String) throws { values[key] = data }
  func remove(_ key: String) throws { values.removeValue(forKey: key) }
}
