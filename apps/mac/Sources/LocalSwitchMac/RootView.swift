import AppKit
import LocalSwitchCore
import SwiftUI
import UniformTypeIdentifiers

enum SwitchPage: String, CaseIterable {
  case workspace = "Workspace"
  case models = "Models"
  case device = "This Mac"
  case settings = "Preferences"
  var symbol: String {
    switch self {
    case .workspace: return "bubble.left.and.bubble.right"
    case .models: return "square.stack.3d.up"
    case .device: return "desktopcomputer"
    case .settings: return "slider.horizontal.3"
    }
  }
}

struct RootView: View {
  @StateObject private var app: AppModel
  @State private var page: SwitchPage = .workspace
  @State private var sidebarVisible = true
  @State private var windowWidth: CGFloat = 1180
  @State private var pendingDelete: SavedConversation?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduced
  @State private var qaOnboarding = false
  @State private var exploring = false
  @State private var historyQuery = ""
  @State private var exportWarning = false
  @State private var exportText = ""
  @State private var exportPanel: NSSavePanel?
  @State private var searchTask: Task<Void, Never>?
  @State private var searchRequest = UUID()
  @State private var matchingChatIDs = Set<UUID>()
  @State private var searching = false
  private var visibleConversations: [SavedConversation] {
    guard PipAppIdentity.isEnhanced,
      !historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return app.conversations }
    return app.conversations.filter { matchingChatIDs.contains($0.id) }
  }
  init() {
    if let path = Bundle.main.object(forInfoDictionaryKey: "PipHybridAcceptanceRoot") as? String {
      // A dedicated, freshly signed test bundle owns this synthetic lane. No production
      // account/history store is constructed, even if test metadata is invalid.
      guard let bundleID = Bundle.main.bundleIdentifier,
        bundleID.hasPrefix("app.pip.hybrid.acceptance."), path.hasPrefix("/"),
        URL(fileURLWithPath: path).lastPathComponent.hasPrefix("PipHybrid-Acceptance-"),
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == path
      else {
        fatalError("Invalid isolated acceptance configuration; production stores were not opened")
      }
      let preferences = PipAppIdentity.preferences
      _app = StateObject(
        wrappedValue: AppModel(
          root: URL(fileURLWithPath: path).appendingPathComponent("Models"),
          preferences: preferences,
          historySecrets: KeychainSecretStore(service: bundleID + ".history"),
          chatGPTSecrets: PreviewSecretStore(), accountConnectionsEnabled: false))
    } else {
      let preferences = PipAppIdentity.preferences
      _app = StateObject(wrappedValue: AppModel(preferences: preferences))
    }
  }
  private var qaScreen: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "--qa-screen"), args.indices.contains(i + 1) else {
      return nil
    }
    return args[i + 1]
  }
  private var forcedScheme: ColorScheme? {
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "--qa-appearance"), args.indices.contains(i + 1) {
      return args[i + 1] == "dark" ? .dark : .light
    }
    switch app.appearance {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
  }
  var body: some View {
    let p = SwitchPalette(scheme)
    Group {
      if qaOnboarding || (!app.onboardingComplete && qaScreen == nil && !exploring) {
        OnboardingView(
          app: app, models: app.models,
          explore: {
            exploring = true
            qaOnboarding = false
          })
      } else {
        HStack(spacing: 0) {
          if sidebarVisible {
            sidebar(p).frame(width: min(300, max(228, windowWidth * 0.26)))
              .background(p.surface)
          }
          VStack(spacing: 0) {
            topbar(p)
            VStack(spacing: 0) {
              if exploring && !app.onboardingComplete {
                HStack(alignment: .center, spacing: 12) {
                  Image(systemName: "sparkle.magnifyingglass").accessibilityHidden(true)
                  Text(
                    app.isBusy
                      ? "Finish or stop the current response before resuming setup."
                      : "Have a look around. Resume setup whenever you’re ready."
                  )
                  .font(.pip(size: 12)).fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  Button("Resume setup") {
                    exploring = false
                    qaOnboarding = qaScreen != nil
                  }.buttonStyle(QuietButtonStyle()).disabled(app.isBusy)
                }.padding(14).background(p.quiet)
              }
              if let error = app.error {
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: "exclamationmark.triangle")
                  Text(error).textSelection(.enabled).frame(
                    maxWidth: .infinity, alignment: .leading)
                  Button {
                    app.error = nil
                  } label: {
                    Image(systemName: "xmark")
                  }
                  .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
                .font(.pip(size: 12)).foregroundStyle(p.error)
                .padding(14).background(p.error.opacity(0.08))
              }
              Group {
                switch page {
                case .workspace:
                  WorkspaceView(
                    app: app, models: app.models, openModels: { page = .models },
                    openPreferences: { page = .settings })
                case .models: ModelLibraryView(app: app, models: app.models)
                case .device: DeviceView(device: app.device)
                case .settings: PreferencesView(app: app)
                }
              }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(p.panel)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
              RoundedRectangle(cornerRadius: 18).strokeBorder(p.border.opacity(0.5), lineWidth: 1)
            )
            .padding(.trailing, 12).padding(.bottom, 12)
          }
        }
        .background(p.canvas)
      }
    }
    .background(
      GeometryReader { geometry in
        Color.clear.onAppear { windowWidth = geometry.size.width }
          .onChange(of: geometry.size.width) { _, width in windowWidth = width }
      }
    )
    .confirmationDialog(
      "Delete this chat?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete chat", role: .destructive) {
        if let chat = pendingDelete { app.deleteConversation(chat.id) }
        pendingDelete = nil
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      Text("This deletes the locally saved conversation. It cannot be undone.")
    }
    .confirmationDialog(
      "Export an unencrypted copy?", isPresented: $exportWarning,
      titleVisibility: .visible
    ) {
      Button("Choose destination") { saveExport() }
      Button("Cancel", role: .cancel) { exportText = "" }
    } message: {
      Text(
        "Only this chat and its draft will be exported. The Markdown file is outside encrypted history. Anyone with access to that file can read it."
      )
    }
    .onChange(of: exportWarning) { _, presented in
      if !presented { exportText = "" }
    }
    .onChange(of: historyQuery) { _, _ in search(app.conversations) }
    .onReceive(app.$conversations) { search($0) }
    .onChange(of: sidebarVisible) { _, visible in
      if !visible { clearSearch() }
    }
    .onChange(of: app.historyAvailable) { _, available in
      if !available {
        clearSearch()
        exportWarning = false
        exportText = ""
        exportPanel?.cancel(nil)
        exportPanel = nil
      }
    }
    .onDisappear {
      clearSearch()
      exportWarning = false
      exportText = ""
      exportPanel?.cancel(nil)
      exportPanel = nil
    }
    .onChange(of: page) { _, _ in
      app.pendingCloudReview = nil
      app.completionPulse = nil
    }
    .onChange(of: app.onboardingComplete) { _, complete in
      if complete {
        qaOnboarding = false
        exploring = false
      }
    }
    .foregroundStyle(p.ink)
    .tint(p.ink)
    .overlay(alignment: .top) {
      if ProcessInfo.processInfo.arguments.contains("--qa-output") {
        Text("Sample").font(.pip(size: 11, weight: .medium))
          .foregroundStyle(p.secondary).padding(.horizontal, 10).padding(.vertical, 5)
          .background(p.quiet, in: Capsule()).padding(.top, 16).allowsHitTesting(false)
      }
    }
    .preferredColorScheme(forcedScheme)
    .onAppear {
      SwitchAppDelegate.model = app
      let args = ProcessInfo.processInfo.arguments
      if args.contains("--qa-output"), qaScreen == "workspace" {
        if args.contains("--qa-exploring") {
          app.onboardingComplete = false
          exploring = true
        }

      }
      if args.contains("--qa-output"), args.contains("--qa-many-chats") {
        app.conversations = (1...18).map { number in
          SavedConversation(
            id: UUID(), messages: [ChatMessage(role: "user", content: "Synthetic chat \(number)")])
        }
      }
      if args.contains("--qa-output"), PipAppIdentity.isEnhanced,
        let index = args.firstIndex(of: "--qa-history-query"), args.indices.contains(index + 1)
      {
        historyQuery = args[index + 1]
      }
      if let qaScreen {
        switch qaScreen {
        case "onboarding":
          if args.contains("--qa-output") { app.onboardingComplete = false }
          qaOnboarding = true
        case "models": page = .models
        case "device": page = .device
        case "settings": page = .settings
        default: page = .workspace
        }
      }
    }
  }
  private func sidebar(_ p: SwitchPalette) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        PipView(size: 36, live: false)
        Text(PipAppIdentity.displayName).font(
          .pip(size: PipAppIdentity.isEnhanced ? 16 : 19, weight: .semibold)
        )
        .lineLimit(2)
      }.padding(.top, 44).padding(.horizontal, 20).padding(.bottom, 26)
      Button {
        app.newChat()
        page = .workspace
      } label: {
        Label("New chat", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 14).disabled(app.isBusy)
        .keyboardShortcut("n", modifiers: .command)
      VStack(spacing: 4) {
        ForEach(SwitchPage.allCases, id: \.self) { item in
          Button {
            page = item
          } label: {
            HStack(spacing: 11) {
              Image(systemName: item.symbol).frame(width: 18)
              Text(item.rawValue).fontWeight(page == item ? .semibold : .regular)
              Spacer()
              if page == item { Capsule().fill(p.ink).frame(width: 3, height: 13) }
            }
            .font(.pip(size: 13)).padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(page == item ? p.quiet : .clear, in: RoundedRectangle(cornerRadius: 8))
          }.buttonStyle(.plain)
            .accessibilityAddTraits(page == item ? .isSelected : [])
        }
      }.padding(.horizontal, 14).padding(.top, 18)
      if !app.conversations.isEmpty {
        Text("Recent chats").font(.pip(size: 11, weight: .medium)).foregroundStyle(p.secondary)
          .padding(.horizontal, 25).padding(.top, 27).padding(.bottom, 9)
        if PipAppIdentity.isEnhanced {
          HStack(spacing: 5) {
            TextField("Search saved chats", text: $historyQuery)
              .textFieldStyle(.roundedBorder).accessibilityLabel("Search saved chats")
              .disabled(
                !app.historyAvailable && !ProcessInfo.processInfo.arguments.contains("--qa-output"))
            if !historyQuery.isEmpty {
              Button {
                historyQuery = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
              }
              .buttonStyle(.plain).accessibilityLabel("Clear saved chat search")
            }
          }.padding(.horizontal, 18)
          Text(
            searching
              ? "Searching saved chats…"
              : "\(visibleConversations.count) of \(app.conversations.count) saved chats"
          )
          .font(.pip(size: 10)).foregroundStyle(p.secondary)
          .padding(.horizontal, 25).padding(.vertical, 5)
          if visibleConversations.isEmpty && !searching {
            Text("No saved chats match.").font(.pip(size: 11)).foregroundStyle(p.secondary)
              .padding(.horizontal, 25).padding(.vertical, 6)
          }
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleConversations) { conversation in
              Button {
                app.openConversation(conversation.id)
                page = .workspace
              } label: {
                Text(conversation.title).lineLimit(1).font(.pip(size: 12))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
              }.buttonStyle(.plain).disabled(app.isBusy)
                .help(conversation.title)
                .contextMenu {
                  Button("Delete chat", role: .destructive) { pendingDelete = conversation }
                    .disabled(app.isBusy)
                }
            }
          }.padding(.horizontal, 13)
        }
      }
      Spacer(minLength: 14)
      VStack(alignment: .leading, spacing: 9) {
        Label(
          app.cloudMode ? "Cloud review on" : "Local only",
          systemImage: app.cloudMode ? "arrow.up.right.circle" : "desktopcomputer"
        ).font(.pip(size: 12, weight: .medium))
        Text(
          app.cloudMode
            ? "Every cloud request needs review.\nLocal history stays encrypted."
            : "Inference on your Mac.\nNo AI account needed."
        )
        .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3).fixedSize(
          horizontal: false, vertical: true)
        HStack(spacing: 5) {
          Circle().fill(p.accent).frame(width: 6, height: 6)
          Text("Mac alpha · " + PipAppIdentity.version).font(.pip(size: 10, design: .monospaced))
            .foregroundStyle(
              p.secondary)
        }
      }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .padding(14)
    }
  }
  private func topbar(_ p: SwitchPalette) -> some View {
    HStack(spacing: 12) {
      Button {
        sidebarVisible.toggle()
      } label: {
        Image(systemName: "sidebar.left").font(.pip(size: 14))
      }
      .buttonStyle(.plain).padding(6)
      .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
      .keyboardShortcut("s", modifiers: [.command, .control])
      Text(page.rawValue).font(.pip(size: 12, weight: .medium))
      Spacer()
      Text(app.status).font(.pip(size: 11)).foregroundStyle(p.secondary).lineLimit(1)
      if PipAppIdentity.isEnhanced && page == .workspace {
        Button {
          guard !app.isBusy else { return }
          let title = String(
            (app.messages.first(where: { $0.role == "user" })?.content
              ?? app.draft).prefix(70))
          exportText = ConversationTools.markdown(
            title: title, messages: app.messages, draft: app.draft)
          exportWarning = true
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(app.isBusy || (app.messages.isEmpty && app.draft.isEmpty))
        .accessibilityLabel("Export current chat as Markdown")
        .help("Export current chat as Markdown")
        .keyboardShortcut("e", modifiers: [.command, .shift])
      }
      if app.isBusy && page != .workspace {
        Button("Stop", systemImage: "stop.fill") { app.stop() }
          .buttonStyle(QuietButtonStyle())
          .accessibilityLabel("Stop active operation")
          .keyboardShortcut(".", modifiers: .command)
      }
      StatusPill(title: app.cloudMode ? "ChatGPT · review first" : "On this Mac")
    }
    .padding(.leading, sidebarVisible ? 12 : 82).padding(.trailing, 21)
    .frame(height: 54)
  }
  private func saveExport() {
    guard PipAppIdentity.isEnhanced, !exportText.isEmpty, exportPanel == nil else { return }
    let snapshot = exportText
    exportText = ""
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = "Hybrid chat.md"
    panel.canCreateDirectories = true
    panel.prompt = "Export"
    panel.message = "This is an unencrypted copy of the selected chat and its draft."
    let model = app
    exportPanel = panel
    panel.begin { [weak panel, weak model] response in
      guard let panel, exportPanel === panel else { return }
      defer {
        if exportPanel === panel { exportPanel = nil }
      }
      guard response == .OK, let destination = panel.url, let model else { return }
      do {
        try Data(snapshot.utf8).write(to: destination, options: .atomic)
        model.status = "Markdown exported"
      } catch {
        model.status = "Export was not saved"
        model.error = "The export could not be saved. Your chat and draft are unchanged."
      }
    }
  }
  private func clearSearch() {
    searchTask?.cancel()
    searchTask = nil
    searchRequest = UUID()
    historyQuery = ""
    matchingChatIDs = []
    searching = false
  }
  private func search(_ conversations: [SavedConversation]) {
    searchTask?.cancel()
    let request = UUID()
    searchRequest = request
    guard PipAppIdentity.isEnhanced,
      !historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      searchTask = nil
      matchingChatIDs = []
      searching = false
      return
    }
    let query = historyQuery
    matchingChatIDs = []
    searching = true
    searchTask = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      guard !Task.isCancelled else { return }
      let worker = Task.detached(priority: .userInitiated) {
        Set(ConversationTools.matching(conversations, query: query).map(\.id))
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled, searchRequest == request else { return }
      matchingChatIDs = result
      searching = false
    }
  }

}
