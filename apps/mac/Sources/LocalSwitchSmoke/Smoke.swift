import Foundation
import LocalSwitchCore

@main struct Smoke {
  @MainActor static func main() async {
    do {
      let device = DeviceSnapshot.inspect()
      print("HARDWARE " + String(data: try JSONEncoder().encode(device), encoding: .utf8)!)
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

private final class SmokeSecrets: SecretStore {
  private var values: [String: Data] = [:]
  func read(_ key: String) throws -> Data? { values[key] }
  func write(_ data: Data, for key: String) throws { values[key] = data }
  func remove(_ key: String) throws { values.removeValue(forKey: key) }
}
