import AppKit
import CryptoKit
import SwiftUI

/// Opt-in sampling of our own native view. Never captures a display, account or production app model.
@MainActor final class PipMotionQA {
  private static var active: PipMotionQA?
  static func isRequested(_ arguments: [String]) -> Bool {
    arguments.contains("--qa-output") && arguments.contains("--qa-motion-output")
  }
  static func startIfRequested(arguments: [String]) -> Bool {
    guard isRequested(arguments) else { return false }
    NSApp.setActivationPolicy(.accessory)
    for window in NSApp.windows { window.orderOut(nil) }
    guard let index = arguments.firstIndex(of: "--qa-motion-output"),
      arguments.indices.contains(index + 1)
    else {
      fputs("Pip motion QA needs an output directory.\n", stderr)
      DispatchQueue.main.async { exit(2) }
      return true
    }
    let recorder = PipMotionQA(directory: URL(fileURLWithPath: arguments[index + 1]))
    active = recorder
    Task { await recorder.record() }
    return true
  }

  private final class Pose: ObservableObject {
    @Published var working = false
    @Published var greeting = false
    @Published var completionID: UUID?
    @Published var locked = false
    @Published var reduced = false
    @Published var present = true
    @Published var mountID = UUID()
  }
  private struct Canvas: View {
    @ObservedObject var pose: Pose
    var body: some View {
      ZStack {
        SwitchPalette(.light).canvas
        if pose.present {
          PipView(
            size: 160, working: pose.working, greeting: pose.greeting,
            completionID: pose.completionID, isLocked: pose.locked
          ).id(pose.mountID)
        }
      }.frame(width: 256, height: 256)
        .environment(\.colorScheme, .light)
        .environment(\.pipMotionQAReduceMotion, pose.reduced)
    }
  }
  private struct Event {
    let after: Double
    let name: String
    let update: (Pose) -> Void
  }
  private struct Scenario {
    let name: String
    let duration: Double
    let initial: (Pose) -> Void
    let events: [Event]
  }
  private struct EventReceipt: Encodable {
    let name: String
    let requestedSeconds: Double
    let appliedSeconds: Double
  }
  private struct FrameReceipt: Encodable {
    let file: String
    let sampledSeconds: Double
    let captureMilliseconds: Double
    let sha256: String
  }
  private struct ScenarioReceipt: Encodable {
    let scenario: String
    let events: [EventReceipt]
    let frames: [FrameReceipt]
  }
  private struct Receipt: Encodable {
    let version = 1
    let scope =
      "NSHostingView cacheDisplay of original Pip only; no screen capture or production model"
    let timing =
      "Monotonic observed sample times. Sampling overhead affects timing; not a display FPS benchmark."
    let reducedMotion =
      "Environment override in QA view only; no macOS accessibility preference changed."
    let macOS: String
    let scenarios: [ScenarioReceipt]
  }
  private let directory: URL
  private init(directory: URL) { self.directory = directory }
  private func elapsed(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
  private var scenarios: [Scenario] {
    [
      Scenario(name: "greeting", duration: 1, initial: { $0.greeting = true }, events: []),
      Scenario(
        name: "completion", duration: 1.1, initial: { $0.working = true },
        events: [
          Event(
            after: 0.20, name: "terminal UUID arrives while still working",
            update: { $0.completionID = UUID() }),
          Event(after: 0.23, name: "working ends", update: { $0.working = false }),
        ]),
      Scenario(
        name: "interrupted", duration: 1.3, initial: { $0.greeting = true },
        events: [
          Event(after: 0.22, name: "working interrupts greeting", update: { $0.working = true }),
          Event(after: 0.40, name: "work ends without completion", update: { $0.working = false }),
          Event(after: 0.55, name: "confirmed completion", update: { $0.completionID = UUID() }),
          Event(after: 0.61, name: "new work interrupts nod", update: { $0.working = true }),
          Event(
            after: 0.80, name: "work ends without another UUID", update: { $0.working = false }),
        ]),
      Scenario(
        name: "reduced", duration: 1.1,
        initial: {
          $0.greeting = true
          $0.reduced = true
        },
        events: [
          Event(after: 0.20, name: "work begins, reduced motion", update: { $0.working = true }),
          Event(
            after: 0.40, name: "confirmed completion, reduced motion",
            update: {
              $0.working = false
              $0.completionID = UUID()
            }),
        ]),
      Scenario(
        name: "runtime-reduce-remount", duration: 1.45, initial: { _ in },
        events: [
          Event(after: 0.20, name: "confirmed completion", update: { $0.completionID = UUID() }),
          Event(
            after: 0.32, name: "reduce motion enabled during nod", update: { $0.reduced = true }),
          Event(
            after: 0.52, name: "reduce motion disabled; no replay", update: { $0.reduced = false }),
          Event(
            after: 0.72, name: "another confirmed completion", update: { $0.completionID = UUID() }),
          Event(after: 0.82, name: "view removed during nod", update: { $0.present = false }),
          Event(
            after: 0.95, name: "view remounted with existing UUID",
            update: {
              $0.mountID = UUID()
              $0.present = true
            }),
        ]),
      Scenario(
        name: "locked", duration: 1.2, initial: { $0.greeting = true },
        events: [
          Event(after: 0.30, name: "lock interrupts greeting", update: { $0.locked = true }),
          Event(after: 0.45, name: "completion while locked", update: { $0.completionID = UUID() }),
          Event(after: 0.70, name: "unlock; no stale celebration", update: { $0.locked = false }),
        ]),
    ]
  }
  private func record() async {
    var window: NSWindow?
    do {
      guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw CocoaError(.fileWriteFileExists)
      }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var receipts: [ScenarioReceipt] = []
      for scenario in scenarios {
        let pose = Pose()
        scenario.initial(pose)
        let host = NSHostingView(rootView: Canvas(pose: pose))
        host.frame = NSRect(x: 0, y: 0, width: 256, height: 256)
        let ownWindow = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 256, height: 256),
          styleMask: [.borderless], backing: .buffered, defer: false)
        ownWindow.isReleasedWhenClosed = false
        ownWindow.contentView = host
        // An offscreen non-key window gives SwiftUI a native lifecycle without foregrounding anything.
        ownWindow.orderBack(nil)
        window = ownWindow
        let start = DispatchTime.now().uptimeNanoseconds
        var frameReceipts: [FrameReceipt] = []
        var eventReceipts: [EventReceipt] = []
        var nextEvent = 0
        while elapsed(since: start) < scenario.duration {
          let observed = elapsed(since: start)
          while nextEvent < scenario.events.count, observed >= scenario.events[nextEvent].after {
            let event = scenario.events[nextEvent]
            event.update(pose)
            eventReceipts.append(
              EventReceipt(
                name: event.name,
                requestedSeconds: event.after, appliedSeconds: elapsed(since: start)))
            nextEvent += 1
          }
          host.layoutSubtreeIfNeeded()
          let sampled = elapsed(since: start)
          guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
          }
          host.cacheDisplay(in: host.bounds, to: bitmap)
          guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
          }
          let file = String(format: "%@-%04d.png", scenario.name, frameReceipts.count)
          try data.write(to: directory.appendingPathComponent(file), options: .atomic)
          frameReceipts.append(
            FrameReceipt(
              file: file, sampledSeconds: sampled,
              captureMilliseconds: (elapsed(since: start) - sampled) * 1000,
              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
          try await Task.sleep(nanoseconds: 25_000_000)
        }
        ownWindow.orderOut(nil)
        ownWindow.close()
        window = nil
        receipts.append(
          ScenarioReceipt(scenario: scenario.name, events: eventReceipts, frames: frameReceipts))
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let result = Receipt(
        macOS: ProcessInfo.processInfo.operatingSystemVersionString, scenarios: receipts)
      try encoder.encode(result).write(
        to: directory.appendingPathComponent("samples.json"), options: .atomic)
      print("Pip motion QA captured \(receipts.count) scenarios into the requested directory.")
      DispatchQueue.main.async { exit(0) }
    } catch {
      window?.orderOut(nil)
      window?.close()
      fputs("Pip motion QA capture failed: \(error.localizedDescription)\n", stderr)
      DispatchQueue.main.async { exit(2) }
    }
  }
}
