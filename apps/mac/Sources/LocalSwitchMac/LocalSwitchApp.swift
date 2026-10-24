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
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = Self.model else { return .terminateNow }
    guard model.prepareForTermination() else { return .terminateCancel }
    model.completeTerminationAfterCheckpoint()
    return .terminateNow
  }
  func handleWindowClose() -> Bool {
    guard let model = Self.model else { return true }
    guard model.prepareForTermination() else { return false }
    if shouldTerminateAfterLastWindowClosed {
      model.completeTerminationAfterCheckpoint()
    }
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
    Self.model?.finishProcessTermination()
    if ProcessInfo.processInfo.arguments.contains("--qa-output") {
      UserDefaults.standard.removePersistentDomain(
        forName: PipAppIdentity.bundleIdentifier
          + ".qa.\(ProcessInfo.processInfo.processIdentifier)")
    }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NotificationCenter.default.addObserver(
      self, selector: #selector(mainWindowBecameMain(_:)),
      name: NSWindow.didBecomeMainNotification, object: nil)
    DispatchQueue.main.async { [weak self] in self?.installCloseGuards(on: NSApp.windows) }
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
    shouldTerminateAfterLastWindowClosed
  }
  private var shouldTerminateAfterLastWindowClosed: Bool {
    !PipMotionQA.isRequested(ProcessInfo.processInfo.arguments)
  }

  @objc private func mainWindowBecameMain(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    installCloseGuards(on: [window])
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window else { return }
      self.installCloseGuards(on: [window])
    }
  }

  private var closeGuardDelegates: [ObjectIdentifier: CloseGuardWindowDelegate] = [:]

  private func installCloseGuards(on windows: [NSWindow]) {
    for window in windows where
      window.identifier?.rawValue == "main" || window.title == PipAppIdentity.displayName
    {
      let key = ObjectIdentifier(window)
      if let proxy = closeGuardDelegates[key] {
        if window.delegate !== proxy {
          proxy.downstream = window.delegate
          window.delegate = proxy
        }
        continue
      }
      let proxy = CloseGuardWindowDelegate(owner: self, downstream: window.delegate)
      closeGuardDelegates[key] = proxy
      window.delegate = proxy
    }
  }
}

@MainActor private final class CloseGuardWindowDelegate: NSObject, NSWindowDelegate {
  weak var owner: SwitchAppDelegate?
  weak var downstream: (any NSWindowDelegate)?

  init(owner: SwitchAppDelegate, downstream: (any NSWindowDelegate)?) {
    self.owner = owner
    self.downstream = downstream
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let downstream, downstream.windowShouldClose?(sender) == false { return false }
    return owner?.handleWindowClose() ?? true
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || downstream?.responds(to: selector) == true
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if let downstream, downstream.responds(to: selector) { return downstream }
    return super.forwardingTarget(for: selector)
  }
}
