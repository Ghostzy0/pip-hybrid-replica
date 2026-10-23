import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import LocalSwitchCore

/// Uses the production Process, sandbox, loopback authentication and streaming paths.
/// The executable is a temporary Python HTTP fixture, not llama.cpp or model inference.
@MainActor final class RuntimeCancellationTests: XCTestCase {
  func testOwnedProcessStopCoalescesSuppressesLateChunksAndCanReload() async throws {
    let fixture = try CancellationRuntimeFixture()
    let previousDirectory = getenv("LOCALSWITCH_RUNTIME_DIR").map { String(cString: $0) }
    guard setenv("LOCALSWITCH_RUNTIME_DIR", fixture.root.path, 1) == 0 else {
      try? FileManager.default.removeItem(at: fixture.root)
      throw CancellationFixtureError.timeout("Could not scope the fixture runtime directory")
    }
    let runtime = LocalRuntime()
    var generation: Task<Void, Never>?
    defer {
      generation?.cancel()
      // Only this instance's owned child is signalled, including on a failed assertion/throw.
      runtime.terminateImmediately()
      if let previousDirectory {
        setenv("LOCALSWITCH_RUNTIME_DIR", previousDirectory, 1)
      } else {
        unsetenv("LOCALSWITCH_RUNTIME_DIR")
      }
      try? FileManager.default.removeItem(at: fixture.root)
    }

    do {
      guard try LocalRuntime.runtimeDirectory().standardizedFileURL == fixture.root.standardizedFileURL
      else {
        throw CancellationFixtureError.timeout("Runtime override was not honored; fixture refused to load")
      }
      try await load(fixture, into: runtime)
      let firstPID = try XCTUnwrap(runtime.processID)
      XCTAssertEqual(Darwin.kill(firstPID, 0), 0)
      let unauthorizedStatus = try await runtime.authorizationProbe()
      XCTAssertEqual(unauthorizedStatus, 401)

      var received = ""
      var generationFinished = false
      var generationFailed = false
      generation = Task {
        defer { generationFinished = true }
        do {
          try await runtime.generate(messages: [RuntimeMessage(role: "user", content: "Synthetic")]) {
            received += $0
          }
        } catch { generationFailed = true }
      }
      try await waitUntil("initial synthetic stream chunk", timeout: 5) { !received.isEmpty }
      XCTAssertEqual(received, "Synthetic partial")

      let started = Date()
      let firstStop = Task { await runtime.stop() }
      let secondStop = Task { await runtime.stop() }
      try await waitUntil("Stop operation started", timeout: 2) { runtime.state == "stopping" }
      // Release a real server-side chunk while Stop is pending and the child is still alive.
      try Data().write(to: fixture.root.appendingPathComponent("release-late"))
      await firstStop.value
      await secondStop.value
      XCTAssertLessThan(Date().timeIntervalSince(started), 5)
      try await waitUntil("cancelled generation completion", timeout: 3) { generationFinished }
      XCTAssertTrue(generationFailed)
      XCTAssertEqual(received, "Synthetic partial", "A late callback escaped the stopped epoch")
      XCTAssertEqual(runtime.state, "stopped")
      XCTAssertTrue(runtime.lastStopConfirmed)
      XCTAssertNil(runtime.processID)
      XCTAssertNil(runtime.loadedModelID)
      assertProcessGone(firstPID)
      // The fixture ignores SIGTERM, attempts a later chunk, then needs SIGKILL.
      // One signal marker shows the two overlapping Stops shared the same operation.
      let signals = try String(contentsOf: fixture.root.appendingPathComponent("term-signals"))
      XCTAssertEqual(signals, "term\n")
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("late-attempt").path))

      try await load(fixture, into: runtime)
      let reloadedPID = try XCTUnwrap(runtime.processID)
      XCTAssertNotEqual(reloadedPID, firstPID)
      XCTAssertEqual(runtime.state, "ready")
      await runtime.stop()
      XCTAssertTrue(runtime.lastStopConfirmed)
      assertProcessGone(reloadedPID)
      XCTAssertEqual(received, "Synthetic partial")
    } catch {
      generation?.cancel()
      await runtime.stop()
      throw error
    }
  }

  private func assertProcessGone(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) {
    let result = Darwin.kill(pid, 0)
    let failure = errno
    XCTAssertEqual(result, -1, file: file, line: line)
    XCTAssertEqual(failure, ESRCH, file: file, line: line)
  }

  private func load(_ fixture: CancellationRuntimeFixture, into runtime: LocalRuntime) async throws {
    let loading = Task { try await runtime.load(model: fixture.model, file: fixture.modelFile) }
    defer { loading.cancel() }
    try await waitUntil("synthetic runtime startup", timeout: 8) {
      runtime.state == "ready" || runtime.state == "failed"
    }
    try await loading.value
  }

  private func waitUntil(
    _ description: String, timeout: TimeInterval, predicate: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
      guard Date() < deadline else { throw CancellationFixtureError.timeout(description) }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

private enum CancellationFixtureError: Error {
  case timeout(String)
}

private struct CancellationRuntimeFixture {
  let root: URL
  let modelFile: URL
  let model: ModelDescriptor

  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PipHybrid-runtime-cancellation-" + UUID().uuidString, isDirectory: true
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      // Header-only synthetic data passes the production magic/version/size/hash checks.
      // It is never parsed as a real model because our temporary HTTP executable ignores it.
      let bytes = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0])
      let file = directory.appendingPathComponent("synthetic.gguf")
      try bytes.write(to: file)
      let executable = directory.appendingPathComponent("llama-server")
      let script = Data(Self.server.utf8)
      try script.write(to: executable)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
      let manifest = ["llama-server": Self.sha256(script)]
      try JSONEncoder().encode(manifest).write(
        to: directory.appendingPathComponent("localswitch-runtime.json"))
      root = directory
      modelFile = file
      model = ModelDescriptor(
        id: "synthetic-stop-fixture", name: "Synthetic process fixture", summary: "No inference",
        filename: "synthetic.gguf", bytes: Int64(bytes.count), sha256: Self.sha256(bytes),
        downloadURL: URL(string: "https://example.invalid/never-downloaded.gguf")!,
        licenseURL: URL(string: "https://example.invalid/no-model-license")!, memoryGiB: 0.001)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static let server = #"""
#!/usr/bin/python3
import http.server
import json
import os
import pathlib
import signal
import sys
import time

# Hard lifetime limit survives a failed test, cancelled load, or lost Swift owner.
signal.alarm(25)
root = pathlib.Path(__file__).parent
def record_term(number, frame):
    with (root / "term-signals").open("a") as marker:
        marker.write("term\n")
signal.signal(signal.SIGTERM, record_term)
def argument(name):
    return sys.argv[sys.argv.index(name) + 1]
alias = argument("--alias")
port = int(argument("--port"))
authorization = "Bearer " + os.environ["LLAMA_API_KEY"]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, format, *args):
        pass  # Never log the temporary authorization value or request content.
    def allowed(self):
        if self.headers.get("Authorization") == authorization:
            return True
        self.send_response(401)
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False
    def do_GET(self):
        if not self.allowed():
            return
        body = json.dumps({"data": [{"id": alias}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        if not self.allowed():
            return
        count = int(self.headers.get("Content-Length", "0"))
        if count > 64000:
            self.send_error(413)
            return
        self.rfile.read(count)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        def emit(text):
            event = {"choices": [{"delta": {"content": text}, "finish_reason": None}]}
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
        try:
            emit("Synthetic partial")
            deadline = time.monotonic() + 8
            while not (root / "release-late").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            (root / "late-attempt").write_text("attempted")
            emit(" late chunk must not arrive")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.daemon_threads = True
server.serve_forever(poll_interval=0.05)
"""#
}
