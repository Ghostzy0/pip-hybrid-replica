import CryptoKit
import XCTest

@testable import LocalSwitchCore

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
  static var response: (URLRequest) throws -> (Int, [String: String], Data) = { _ in
    (500, [:], Data())
  }
  static var chunkDelay: TimeInterval = 0
  private let lock = NSLock()
  private var stopped = false
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "huggingface.co"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, headers, body) = try Self.response(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if Self.chunkDelay > 0 {
        let split = body.count / 2
        client?.urlProtocol(self, didLoad: body.prefix(split))
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.chunkDelay) { [self] in
          lock.lock()
          let stopped = stopped
          lock.unlock()
          guard !stopped else { return }
          client?.urlProtocol(self, didLoad: body.dropFirst(split))
          client?.urlProtocolDidFinishLoading(self)
        }
      } else {
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
      }
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
}

final class HardwareDownloadTests: XCTestCase {
  override func tearDown() {
    ModelURLProtocol.chunkDelay = 0
    super.tearDown()
  }
  let payload = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0] + Array(repeating: UInt8(42), count: 64))
  func descriptor(data: Data? = nil, id: String = "fixture") -> ModelDescriptor {
    let data = data ?? payload
    return ModelDescriptor(
      id: id, name: "Fixture", summary: "Synthetic bytes for integrity tests only",
      filename: "fixture.gguf", bytes: Int64(data.count),
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      downloadURL: URL(string: "https://huggingface.co/fixture/model/resolve/pinned/model.gguf")!,
      licenseURL: URL(string: "https://huggingface.co/fixture/license")!, memoryGiB: 2)
  }
  func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LocalSwitchTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  @MainActor func store(root: URL) throws -> ModelStore {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelURLProtocol.self]
    return try ModelStore(root: root, configuration: configuration)
  }

  func testUnifiedMemoryNeverAddsMetalPoolToPhysicalMemory() {
    let gib: UInt64 = 1_073_741_824
    let device = DeviceSnapshot(
      chip: "Fixture", physicalMemory: 8 * gib, cpuCount: 4,
      gpuName: "Fixture", unifiedMemory: true, recommendedWorkingSet: 8 * gib, architecture: "arm64"
    )
    XCTAssertTrue(ModelDescriptor.catalogue[0].fits(device))
    XCTAssertFalse(
      ModelDescriptor.catalogue[1].fits(device),
      "5GiB estimate cannot fit after 4GiB OS reserve on an8GiB Mac")
  }
  func testUnknownMetalAndUnsupportedArchitectureFailClosed() {
    let unknown = DeviceSnapshot(
      chip: "Fixture", physicalMemory: 32 * 1_073_741_824, cpuCount: 4,
      gpuName: "Unknown", unifiedMemory: true, recommendedWorkingSet: 0, architecture: "arm64")
    XCTAssertFalse(ModelDescriptor.catalogue[0].fits(unknown))
    let intel = DeviceSnapshot(
      chip: "Fixture", physicalMemory: 32 * 1_073_741_824, cpuCount: 4,
      gpuName: "Fixture", unifiedMemory: false, recommendedWorkingSet: 8 * 1_073_741_824,
      architecture: "x86_64")
    XCTAssertFalse(ModelDescriptor.catalogue[0].fits(intel))
  }
  func testStreamingChecksumAndGGUFRejectCorruption() throws {
    let root = try temporaryRoot()
    let url = root.appendingPathComponent("model.gguf")
    try payload.write(to: url)
    try ModelStore.verifyFile(at: url, model: descriptor())
    var corrupted = payload
    corrupted[20] = 0
    try corrupted.write(to: url)
    XCTAssertThrowsError(try ModelStore.verifyFile(at: url, model: descriptor()))
    try Data(repeating: 0, count: payload.count).write(to: url)
    XCTAssertThrowsError(try ModelStore.verifyFile(at: url, model: descriptor()))
  }
  @MainActor func testSuccessfulInstallCommitsOnlyAfterVerification() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    let data = payload
    ModelURLProtocol.response = { _ in (200, ["Content-Length": "\(data.count)"], data) }
    XCTAssertNil(store.installedURL(for: model))
    await store.install(model)
    XCTAssertEqual(store.phase, "installed", store.error ?? "")
    XCTAssertNotNil(store.installedURL(for: model))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.partial").path))
    try store.remove(model)
    XCTAssertNil(store.installedURL(for: model))
  }
  @MainActor func testRangeResumeUsesExactOffsetAndPreservesBytes() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    let data = payload
    try payload.prefix(16).write(to: root.appendingPathComponent("fixture.partial"))
    ModelURLProtocol.response = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=16-")
      return (
        206,
        [
          "Content-Length": "\(data.count - 16)",
          "Content-Range": "bytes 16-\(data.count - 1)/\(data.count)",
        ], data.dropFirst(16)
      )
    }
    await store.install(model)
    XCTAssertEqual(store.phase, "installed", store.error ?? "")
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.installedURL(for: model))), data)
  }
  @MainActor func testHostIgnoringRangeRestartsRatherThanAppending() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    let data = payload
    try payload.prefix(16).write(to: root.appendingPathComponent("fixture.partial"))
    ModelURLProtocol.response = { _ in (200, ["Content-Length": "\(data.count)"], data) }
    await store.install(model)
    XCTAssertEqual(store.phase, "installed", store.error ?? "")
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.installedURL(for: model))), data)
  }
  @MainActor func testWrongRangeNeverMarksInstalled() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    let data = payload
    try payload.prefix(16).write(to: root.appendingPathComponent("fixture.partial"))
    ModelURLProtocol.response = { _ in
      (206, ["Content-Range": "bytes 0-\(data.count - 1)/\(data.count)"], data)
    }
    await store.install(model)
    XCTAssertEqual(store.phase, "failed")
    XCTAssertNil(store.installedURL(for: model))
  }
  @MainActor func testChecksumFailureRemovesDamagedPartialAndAllowsRetry() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    var data = payload
    data[20] = 0
    ModelURLProtocol.response = { _ in (200, ["Content-Length": "\(data.count)"], data) }
    await store.install(model)
    XCTAssertEqual(store.phase, "failed")
    XCTAssertNil(store.installedURL(for: model))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.partial").path))
    let original = payload
    ModelURLProtocol.response = { _ in (200, ["Content-Length": "\(original.count)"], original) }
    await store.install(model)
    XCTAssertEqual(store.phase, "installed", store.error ?? "")
  }
  @MainActor func testManifestTraversalAndSymlinkCannotEscapeOwnedRoot() async throws {
    let root = try temporaryRoot()
    let store = try store(root: root)
    await store.install(descriptor(id: "../escape"))
    XCTAssertEqual(store.phase, "failed")
    let target = root.appendingPathComponent("unrelated")
    try payload.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("fixture.partial"), withDestinationURL: target)
    await store.install(descriptor())
    XCTAssertEqual(store.phase, "failed")
    XCTAssertEqual(try Data(contentsOf: target), payload)
    XCTAssertThrowsError(try store.remove(descriptor()))
  }
  @MainActor func testChangedInstalledFileInvalidatesReceipt() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    let data = payload
    ModelURLProtocol.response = { _ in (200, ["Content-Length": "\(data.count)"], data) }
    await store.install(model)
    let url = try XCTUnwrap(store.installedURL(for: model))
    try Data().write(to: url)
    XCTAssertNil(store.installedURL(for: model))
  }
  @MainActor func testPausePreservesPartialAndResumeCompletes() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    let data = payload
    ModelURLProtocol.chunkDelay = 0.5
    try payload.prefix(16).write(to: root.appendingPathComponent("fixture.partial"))
    ModelURLProtocol.response = { _ in
      (
        206,
        [
          "Content-Length": "\(data.count-16)",
          "Content-Range": "bytes 16-\(data.count-1)/\(data.count)",
        ], data.dropFirst(16)
      )
    }
    let operation = Task { await store.install(model) }
    for _ in 0..<100 where store.phase != "downloading" {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    store.pause()
    await operation.value
    XCTAssertEqual(store.phase, "paused")
    XCTAssertNil(store.installedURL(for: model))
    let partial = root.appendingPathComponent("fixture.partial")
    let count = try Data(contentsOf: partial).count
    XCTAssertGreaterThan(count, 0)
    XCTAssertLessThan(count, data.count)
    ModelURLProtocol.chunkDelay = 0
    ModelURLProtocol.response = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=\(count)-")
      return (
        206,
        [
          "Content-Length": "\(data.count-count)",
          "Content-Range": "bytes \(count)-\(data.count-1)/\(data.count)",
        ], data.dropFirst(count)
      )
    }
    await store.install(model)
    XCTAssertEqual(store.phase, "installed", store.error ?? "")
  }
  @MainActor func testCancelDeletesOwnedPartialAndLateCallbacksCannotInstall() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    let data = payload
    ModelURLProtocol.chunkDelay = 0.3
    ModelURLProtocol.response = { _ in (200, ["Content-Length": "\(data.count)"], data) }
    let operation = Task { await store.install(model) }
    for _ in 0..<100 where store.phase != "downloading" {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    store.cancel()
    await operation.value
    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertEqual(store.phase, "idle")
    XCTAssertNil(store.activeModelID)
    XCTAssertNil(store.installedURL(for: model))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.partial").path))
  }
  @MainActor func testOversizedAndTruncatedBodiesNeverInstall() async throws {
    let root = try temporaryRoot()
    let model = descriptor()
    let store = try store(root: root)
    let data = payload
    ModelURLProtocol.response = { _ in (200, [:], data + data) }
    await store.install(model)
    XCTAssertEqual(store.phase, "failed")
    XCTAssertNil(store.installedURL(for: model))
    ModelURLProtocol.response = { _ in (200, [:], data.prefix(12)) }
    await store.install(model)
    XCTAssertEqual(store.phase, "failed")
    XCTAssertNil(store.installedURL(for: model))
  }

  @MainActor func testEveryBundledCatalogueIDPassesManifestPathValidation() async throws {
    let root = try temporaryRoot()
    let store = try store(root: root)
    ModelURLProtocol.response = { _ in (404, [:], Data()) }
    for model in ModelDescriptor.catalogue {
      await store.install(model)
      XCTAssertEqual(store.phase, "failed")
      XCTAssertTrue(
        store.error?.contains("HTTP 404") == true, "\(model.id): \(store.error ?? "missing error")")
    }
  }

  func testLargeModelBudgetsCountFullWeightsAndRejectConstrainedMac() throws {
    let gib = 1_073_741_824.0
    let constrained = DeviceSnapshot(
      chip: "Fixture", physicalMemory: 16 * 1_073_741_824, cpuCount: 8,
      gpuName: "Fixture", unifiedMemory: true, recommendedWorkingSet: 12 * 1_073_741_824,
      architecture: "arm64")
    for id in ["qwen3-30b-a3b-q4_k_m", "qwen3-32b-q4_k_m"] {
      let model = try XCTUnwrap(ModelDescriptor.catalogue.first { $0.id == id })
      XCTAssertGreaterThan(
        model.memoryGiB * gib, Double(model.bytes),
        "Budget includes every weight plus working context; active MoE parameters are not the resident weight size"
      )
      XCTAssertFalse(model.fits(constrained))
    }
    XCTAssertEqual(Set(ModelDescriptor.catalogue.map(\.id)).count, ModelDescriptor.catalogue.count)
  }
  func testCompiledCatalogueMatchesReviewedImmutableMetadata() throws {
    var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 { repository.deleteLastPathComponent() }
    let path = repository.appendingPathComponent("docs/engineering/mac-model-catalogue.json")
    // The reviewed metadata ships in both the internal repository and clean source
    // export. A missing fixture is a broken checkout, not a skipped parity check.
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    let entries = try XCTUnwrap(object["models"] as? [[String: Any]])
    XCTAssertEqual(entries.count, ModelDescriptor.catalogue.count)
    for model in ModelDescriptor.catalogue {
      let entry = try XCTUnwrap(entries.first { $0["id"] as? String == model.id })
      XCTAssertEqual(entry["sha256"] as? String, model.sha256)
      XCTAssertEqual((entry["bytes"] as? NSNumber)?.int64Value, model.bytes)
      XCTAssertEqual(entry["downloadURL"] as? String, model.downloadURL.absoluteString)
      XCTAssertEqual(entry["licenseURL"] as? String, model.licenseURL.absoluteString)
      XCTAssertEqual((entry["memoryGiB"] as? NSNumber)?.doubleValue, model.memoryGiB)
      let revision = try XCTUnwrap(entry["revision"] as? String)
      XCTAssertEqual(revision.count, 40)
      XCTAssertTrue(model.downloadURL.path.contains("/resolve/" + revision + "/"))
    }
  }

}
