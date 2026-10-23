import AppKit
import LocalSwitchCore
import SwiftUI

@main
struct LocalSwitchApp: App {
  @NSApplicationDelegateAdaptor(SwitchAppDelegate.self) private var appDelegate
  init() {
    PipTypography.registerBundledFonts()
    let args = ProcessInfo.processInfo.arguments
    if let index = args.firstIndex(of: "--qa-icon"), args.indices.contains(index + 1) {
      // Export before constructing a Scene; this lane creates no window or app state.
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      let view = NSHostingView(
        rootView: PipAppIcon().frame(width: 512, height: 512)
          .environment(\.colorScheme, .light))
      view.frame = NSRect(x: 0, y: 0, width: 512, height: 512)
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
      do { try data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic) } catch {
        fputs("Icon export failed: \(error.localizedDescription)\n", stderr)
        exit(1)
      }
      exit(0)
    }
  }
  var body: some Scene {
    Window(PipAppIdentity.displayName, id: "main") {
      if PipMotionQA.isRequested(ProcessInfo.processInfo.arguments) {
        EmptyView()
      } else {
        RootView().frame(minWidth: 840, minHeight: 600)
      }
    }
    .defaultSize(width: 1180, height: 790)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About " + PipAppIdentity.displayName) {
          NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: PipAppIdentity.displayName,
            .applicationVersion: PipAppIdentity.version + " · Experimental alpha",
            .credits: NSAttributedString(
              string:
                "Local models and explicitly reviewed cloud requests.\nMIT source by Pip Hybrid contributors. Maintained at github.com/Ghostzy0/pip-hybrid.\nBuilt with llama.cpp and Qwen; font and runtime notices included."
            ),
          ])
        }
      }
    }
  }
}

@MainActor final class SwitchAppDelegate: NSObject, NSApplicationDelegate {
  static var model: AppModel?
  func applicationWillTerminate(_ notification: Notification) {
    Self.model?.shutdown()
    if ProcessInfo.processInfo.arguments.contains("--qa-output") {
      UserDefaults.standard.removePersistentDomain(
        forName: PipAppIdentity.bundleIdentifier
          + ".qa.\(ProcessInfo.processInfo.processIdentifier)")
    }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    let args = ProcessInfo.processInfo.arguments
    if PipMotionQA.startIfRequested(arguments: args) { return }
    if let iconIndex = args.firstIndex(of: "--qa-icon"), args.indices.contains(iconIndex + 1) {
      NSApp.setActivationPolicy(.accessory)
      let view = NSHostingView(
        rootView: PipAppIcon().frame(width: 512, height: 512).environment(\.colorScheme, .light))
      view.frame = NSRect(x: 0, y: 0, width: 512, height: 512)
      view.layoutSubtreeIfNeeded()
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
          do {
            try data.write(to: URL(fileURLWithPath: args[iconIndex + 1]), options: .atomic)
          } catch {
            fputs("Pip Hybrid icon export failed: \(error.localizedDescription)\n", stderr)
          }
        }
      }
      DispatchQueue.main.async { NSApp.terminate(nil) }
      return
    }
    guard args.contains("--qa-output"), let index = args.firstIndex(of: "--qa-output"),
      args.indices.contains(index + 1)
    else { return }
    // QA captures only our NSView. This never reads the display, YouTube or any other app.
    NSApp.setActivationPolicy(.accessory)
    func dimension(_ key: String, fallback: CGFloat, minimum: CGFloat) -> CGFloat {
      guard let index = args.firstIndex(of: key), args.indices.contains(index + 1),
        let number = Double(args[index + 1])
      else { return fallback }
      return max(minimum, min(3000, number))
    }
    // Set the final dimensions before the settle interval, so cached drawing cannot
    // contain text left over from the previous width or an unfinished resize.
    DispatchQueue.main.async {
      guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
      window.setContentSize(
        NSSize(
          width: dimension("--qa-width", fallback: 1180, minimum: 840),
          height: dimension("--qa-height", fallback: 790, minimum: 600)))
      window.orderBack(nil)
      window.contentView?.layoutSubtreeIfNeeded()
    }
    if args.contains("--qa-interactive") {
      // Explicit render-only lane for background keyboard/AX checks. It uses the same
      // memory-only account store and skips production history, just like timed captures.
      DispatchQueue.main.async {
        for window in NSApp.windows { window.orderBack(nil) }
      }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      let root =
        NSApp.windows.first(where: { !$0.sheets.isEmpty })
        ?? NSApp.windows.first(where: { $0.contentView != nil })
      guard
        let window =
          ((args.contains("--qa-review") || args.contains("--qa-cloud-review"))
            ? root?.sheets.first : nil) ?? root,
        let view = window.contentView
      else { return }
      window.orderBack(nil)
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
      do { try data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic) } catch {
        fputs("Pip Hybrid QA capture failed: \(error.localizedDescription)\n", stderr)
      }
      if let parent = window.sheetParent { parent.endSheet(window) }
      Self.model?.shutdown()
      // Explicit QA processes own no production session; end even when AppKit is unwinding a sheet.
      DispatchQueue.main.async { exit(0) }
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !PipMotionQA.isRequested(ProcessInfo.processInfo.arguments)
  }
}
