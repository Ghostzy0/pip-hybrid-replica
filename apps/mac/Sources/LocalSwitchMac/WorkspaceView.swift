import AppKit
import LocalSwitchCore
import SwiftUI

struct WorkspaceView: View {
  @ObservedObject var app: AppModel
  @ObservedObject var models: ModelStore
  var openModels: () -> Void
  var openPreferences: () -> Void = {}
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduced
  @State private var composerFocused = false
  @State private var sensitiveReview = false
  @State private var historyNoticeHeight: CGFloat = 28
  var body: some View {
    let p = SwitchPalette(scheme)
    VStack(spacing: 0) {
      if let notice = app.historyNotice, !app.temporarySession {
        VStack(alignment: .leading, spacing: 8) {
          Label("Saved history is locked", systemImage: "lock").font(
            .system(size: 12, weight: .semibold))
          ScrollView {
            Text(notice).font(.pip(size: 11)).foregroundStyle(p.secondary)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background {
                GeometryReader { geometry in
                  Color.clear.preference(key: HistoryNoticeHeight.self, value: geometry.size.height)
                }
              }
          }.frame(height: min(max(historyNoticeHeight, 14), 72))
            .onPreferenceChange(HistoryNoticeHeight.self) { height in
              if height > 0, abs(historyNoticeHeight - height) > 0.5 {
                historyNoticeHeight = height
              }
            }
          HStack {
            Button("Unlock history", action: app.retryHistoryAccess).disabled(app.isBusy)
              .buttonStyle(QuietButtonStyle())
            Button("Use temporary session", action: app.useTemporarySession).disabled(app.isBusy)
              .buttonStyle(
                QuietButtonStyle())
          }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(p.quiet)
          .fixedSize(horizontal: false, vertical: true)
      }
      if app.temporarySession {
        Label(
          "Temporary session · not saved. New chat clears this session.", systemImage: "eye.slash"
        )
        .font(.pip(size: 11)).foregroundStyle(p.secondary).padding(10)
      }
      if app.messages.isEmpty {
        emptyWorkspace(p)
      } else {
        conversation(p)
        composer(p).frame(maxWidth: PipMetrics.contentWidth).padding(.horizontal, 30).padding(
          .bottom, 14)
      }
      HStack(spacing: 5) {
        Image(systemName: "info.circle")
        Text("AI can make mistakes. Check important details.")
      }.font(.pip(size: 10)).foregroundStyle(p.secondary).padding(.bottom, 17)
    }
    .onAppear {
      let args = ProcessInfo.processInfo.arguments
      guard args.contains("--qa-screen"), args.contains("--qa-output") else { return }
      if let i = args.firstIndex(of: "--qa-draft"), args.indices.contains(i + 1) {
        app.draft = args[i + 1]
      }
      if args.contains("--qa-review") { sensitiveReview = true }
      if args.contains("--qa-cloud") { app.cloudMode = true }
      if args.contains("--qa-conversation") {
        // Rendering fixture only. No account, provider request, history read or completion pulse.
        app.messages = [
          ChatMessage(
            role: "user",
            content: "Help me plan a quieter working week. Keep one afternoon free for learning."),
          ChatMessage(
            role: "assistant",
            content:
              "Start with the work that needs your attention most.\n\nMonday and Tuesday\nChoose one important outcome each morning. Keep meetings together so the rest of the day has room to breathe.\n\nWednesday afternoon\nProtect a small learning block. Pick one topic and finish with a note about what you tried.\n\nFriday\nLeave a little space to review the week and make the next one easier.",
            route: "chatgpt", model: "synthetic-render-only"),
          ChatMessage(role: "user", content: "Make that into a short checklist I can use offline."),
          ChatMessage(
            role: "assistant",
            content:
              "Monday: choose the week's main outcome.\nTuesday: finish one focused piece of work.\nWednesday: keep the afternoon for learning.\nThursday: follow up and tidy loose ends.\nFriday: review what helped and plan a light start for Monday."
          ),
        ]
      }
      if args.contains("--qa-output"), args.contains("--qa-cloud-review") {
        // Isolated rendering fixture: no saved registration, credentials or eligible send state.
        app.cloudMode = true
        app.pendingCloudReview = try? CloudReview(
          accountID: "qa-render-only", subject: "qa-render-only",
          accountLabel: "Synthetic preview · no connected account",
          model: "qa-render-model", modelName: "Preview model",
          messages: [
            RuntimeMessage(
              role: "system", content: "You are Pip. Work only with the supplied text."),
            RuntimeMessage(
              role: "user",
              content: "Help me make a plan for Friday. My example contact is alex@example.com."),
          ], sourceFingerprint: "qa-render-only", redacted: false)
      }
    }
    .onChange(of: app.composerFocusRequest) { _, _ in composerFocused = true }
    .modifier(CloudReviewHost(app: app))
  }
  private func emptyWorkspace(_ p: SwitchPalette) -> some View {
    GeometryReader { geometry in
      let compact = geometry.size.height < 500
      ScrollView {
        VStack(spacing: 0) {
          VStack(spacing: compact ? 10 : 19) {
            PipView(
              size: compact ? 46 : 74, working: app.isBusy, greeting: true,
              isLocked: !app.canUseChat)
            VStack(spacing: compact ? 8 : 12) {
              Text("A little space to think.")
                .font(.pip(size: compact ? 24 : 32, weight: .semibold))
                .tracking(compact ? -0.5 : -1).multilineTextAlignment(.center)
              Text(
                app.cloudMode
                  ? "A clear choice about what leaves your Mac."
                  : "Your ideas. Your Mac. A model that stays close."
              )
              .font(.pip(size: compact ? 12 : 14)).foregroundStyle(p.secondary)
              .multilineTextAlignment(.center)
            }
          }.padding(.horizontal, 24).padding(.bottom, compact ? 18 : 31)
          composer(p).frame(maxWidth: PipMetrics.contentWidth).padding(
            .horizontal, compact ? 20 : 34)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { suggestions }
            VStack(spacing: 8) { suggestions }
          }.padding(.top, 17).padding(.horizontal, 20)
        }.padding(.vertical, compact ? 18 : 32)
          .frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
      }
    }
  }
  @ViewBuilder private var suggestions: some View {
    suggestion(
      "Tidy up a draft", prompt: "Help me improve this draft. Keep my tone and make it clearer:\n\n"
    )
    suggestion("Make a plan", prompt: "Help me turn this goal into a practical plan:\n\n")
    suggestion("Explain something", prompt: "Explain this simply, with one example:\n\n")
  }
  private func suggestion(_ title: String, prompt: String) -> some View {
    Button {
      app.draft =
        app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? prompt : prompt + app.draft
      composerFocused = true
    } label: {
      Text(title).font(.pip(size: 11)).padding(.horizontal, 11).padding(.vertical, 7)
    }.buttonStyle(.plain)
      .background(SwitchPalette(scheme).quiet, in: Capsule())
      .disabled(app.isBusy)
  }
  private func composer(_ p: SwitchPalette) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      ZStack(alignment: .topLeading) {
        if app.draft.isEmpty {
          Text("What would you like to work on?")
            .font(.pip(size: 14)).foregroundStyle(p.secondary)
            .padding(.leading, 5).padding(.top, 8).allowsHitTesting(false)
        }
        PromptEditor(
          text: $app.draft, wantsFocus: $composerFocused,
          inputLabel: app.cloudMode ? "Draft for ChatGPT review" : "Message to local model"
        )
        .frame(height: app.messages.isEmpty ? 54 : 70)
        .accessibilityLabel(app.cloudMode ? "Draft for ChatGPT review" : "Message to local model")
      }
      if !SensitiveInfo.scan(app.draft).isEmpty {
        HStack(alignment: .center, spacing: 8) {
          Image(systemName: "eye")
          Text(
            "\(SensitiveInfo.scan(app.draft).count) possible sensitive \(SensitiveInfo.scan(app.draft).count == 1 ? "item" : "items") · scanned on this Mac"
          )
          .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 3)
          Button("Review") {
            composerFocused = false
            sensitiveReview = true
          }.buttonStyle(.link)
        }.font(.pip(size: 11)).foregroundStyle(p.secondary)
          .padding(.horizontal, 8).padding(.vertical, 9)
          .background(p.quiet, in: RoundedRectangle(cornerRadius: 8))
      }
      HStack(spacing: 9) {
        Button(action: app.importTextFile) {
          Image(systemName: "plus").frame(width: 19, height: 19)
        }
        .buttonStyle(.plain).padding(3).disabled(app.isBusy)
        .accessibilityLabel("Add text file").help("Add a UTF-8 text or Markdown file")
        routeMenu(p)
        modelMenu(p)
        Spacer(minLength: 4)
        if app.isBusy {
          Button(action: app.stop) {
            Label("Stop", systemImage: "stop.fill")
          }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(".", modifiers: .command)
            .accessibilityHint(
              app.usingCloudGeneration
                ? "Stops the ChatGPT response" : "Stops the active local operation")
        } else {
          Button(action: app.send) {
            Image(systemName: "arrow.up").font(.pip(size: 14, weight: .semibold))
              .frame(width: 16, height: 16)
          }.buttonStyle(PrimaryButtonStyle())
            .disabled(
              app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !app.canSend
            )
            .accessibilityLabel(app.cloudMode ? "Review ChatGPT request" : "Send message locally")
            .keyboardShortcut(.return, modifiers: .command)
            .help(app.cloudMode ? "Review before sending · ⌘Return" : "Send locally · ⌘Return")
        }
      }
      if app.cloudMode {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { cloudDisclosure(p) }
          VStack(alignment: .leading, spacing: 6) { cloudDisclosure(p) }
        }
      } else if !app.installed {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label(localModelNotice, systemImage: "arrow.down.circle")
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Set up model", action: openModels).buttonStyle(.link)
        }.font(.pip(size: 10)).foregroundStyle(p.secondary)
      }
    }
    .padding(17).background(p.raised, in: RoundedRectangle(cornerRadius: PipMetrics.composerRadius))
    .overlay(
      RoundedRectangle(cornerRadius: PipMetrics.composerRadius).strokeBorder(
        composerFocused ? p.secondary : p.border, lineWidth: 1)
    )
    .padding(7).background(p.quiet.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
    .sheet(isPresented: $sensitiveReview) { SensitiveReviewView(text: app.draft) }
  }
  private var chatGPTEligible: Bool {
    app.chatGPT.protectedStorageAvailable && app.chatGPT.activeAccount?.isSignedIn == true
      && app.chatGPT.activeAccount?.planEnabled == true
      && chatGPTAccountAction == nil
  }
  private var chatGPTAccountAction: String? {
    if let action = app.chatGPTManagementAction { return action }
    if app.chatGPT.isRenewingSession { return "Renewing ChatGPT session…" }
    if app.chatGPT.isAuthorizing { return "Waiting for ChatGPT sign-in…" }
    return nil
  }
  private var localModelNotice: String {
    switch models.phase {
    case "downloading": return "Downloading the local model…"
    case "paused": return "Model download paused. Resume in the library."
    case "verifying": return "Verifying the local model…"
    default: return "Choose an installed local model to send."
    }
  }
  private var cloudNotice: String {
    if let action = chatGPTAccountAction { return "\(action) Your draft is kept." }
    if !app.chatGPT.protectedStorageAvailable {
      return "ChatGPT credentials are locked. Open Settings to unlock."
    }
    if !chatGPTEligible { return "ChatGPT needs attention in Settings. Your draft is kept." }
    if !app.chatGPT.models.contains(where: { $0.slug == app.selectedChatGPTModel }) {
      return "Choose an available ChatGPT model in Settings."
    }
    return "Using ChatGPT plan · Send opens a review"
  }
  private func routeMenu(_ p: SwitchPalette) -> some View {
    Menu {
      Button {
        app.cloudMode = false
      } label: {
        Label("Local only", systemImage: app.cloudMode ? "desktopcomputer" : "checkmark")
      }
      Button {
        app.cloudMode = true
      } label: {
        Label(
          "Review with ChatGPT", systemImage: app.cloudMode ? "checkmark" : "arrow.up.right.circle")
      }.disabled(!chatGPTEligible)
      if !chatGPTEligible {
        Text(chatGPTAccountAction ?? "Connect an eligible account in Settings")
      }
      Divider()
      Button(
        chatGPTEligible ? "Manage ChatGPT accounts…" : "Connect ChatGPT in Settings…",
        action: openPreferences)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: app.cloudMode ? "arrow.up.right.circle" : "desktopcomputer")
        Text(app.cloudMode ? "ChatGPT · review first" : "Local only")
        Image(systemName: "chevron.down").font(.pip(size: 8, weight: .semibold))
      }.font(.pip(size: 10, weight: .medium)).foregroundStyle(p.ink)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(p.quiet, in: Capsule())
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(app.isBusy)
      .accessibilityLabel("Conversation route")
      .help("Choose where your next request is processed")
  }
  private func modelMenu(_ p: SwitchPalette) -> some View {
    Menu {
      if app.cloudMode {
        ForEach(app.chatGPT.models) { model in
          Button {
            app.selectedChatGPTModel = model.slug
          } label: {
            if app.selectedChatGPTModel == model.slug {
              Label(model.displayName, systemImage: "checkmark")
            } else {
              Text(model.displayName)
            }
          }
        }
        if app.chatGPT.models.isEmpty { Text("No available ChatGPT models") }
        Divider()
        Button("Manage ChatGPT accounts…", action: openPreferences)
      } else {
        ForEach(ModelDescriptor.catalogue) { model in
          Button {
            app.selectedModelID = model.id
          } label: {
            if app.selectedModelID == model.id {
              Label(model.name, systemImage: "checkmark")
            } else {
              Text(model.name)
            }
          }
        }
        Divider()
        Button("Manage local models…", action: openModels)
      }
    } label: {
      HStack(spacing: 5) {
        Text(
          app.cloudMode
            ? (app.chatGPT.models.first(where: { $0.slug == app.selectedChatGPTModel })?.displayName
              ?? "Choose a model")
            : app.selectedModel.name
        ).lineLimit(1).truncationMode(.tail)
        Image(systemName: "chevron.down").font(.pip(size: 8, weight: .semibold))
      }.font(.pip(size: 11)).foregroundStyle(p.secondary)
        .frame(maxWidth: 175, alignment: .leading)
    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
      .disabled(
        app.isBusy
          || (app.cloudMode && chatGPTAccountAction != nil)
          || (!app.cloudMode && ["downloading", "paused", "verifying"].contains(models.phase))
      )
      .accessibilityLabel(app.cloudMode ? "ChatGPT model" : "Local model")
  }
  @ViewBuilder private func cloudDisclosure(_ p: SwitchPalette) -> some View {
    Label(
      cloudNotice, systemImage: "arrow.up.right.circle"
    )
    .font(.pip(size: 10)).foregroundStyle(p.secondary)
    .fixedSize(horizontal: false, vertical: true)
    Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
      .font(.pip(size: 10))
    if !chatGPTEligible || app.selectedChatGPTModel.isEmpty {
      Button("Settings", action: openPreferences).buttonStyle(.link).font(.pip(size: 10))
    }
  }
  private func conversation(_ p: SwitchPalette) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 27) {
          ForEach(app.messages) { message in
            ChatMessageRow(
              message: message,
              completionID: app.messages.last?.id == message.id && message.state == "complete"
                ? app.completionPulse : nil
            ).id(message.id)
          }
          Color.clear.frame(height: 1).id("conversation-end")
        }.frame(maxWidth: PipMetrics.contentWidth).padding(.horizontal, 30).padding(.top, 30)
          .padding(.bottom, 25)
          .frame(maxWidth: .infinity)
      }
      // New turns move into view; streamed tokens never repeatedly pull the reader down.
      .onChange(of: app.messages.count) { _, _ in
        if !reduced {
          withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("conversation-end", anchor: .bottom)
          }
        } else {
          proxy.scrollTo("conversation-end", anchor: .bottom)
        }
      }
    }
  }
}

private struct HistoryNoticeHeight: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct SensitiveReviewView: View {
  let text: String
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  @State private var copied = false
  var body: some View {
    let p = SwitchPalette(scheme)
    VStack(alignment: .leading, spacing: 18) {
      Label("A closer look, on this Mac", systemImage: "eye")
        .font(.pip(size: 21, weight: .semibold))
      Text(
        "Pip Hybrid scans for patterns on this Mac. This preview keeps your draft unchanged and does not authorise a cloud request. Local only stays local. ChatGPT requests require a separate review of the exact outgoing conversation."
      )
      .font(.pip(size: 13)).foregroundStyle(p.secondary).lineSpacing(4)
      Text(Array(Set(SensitiveInfo.scan(text).map(\.kind))).sorted().joined(separator: " · "))
        .font(.pip(size: 12, weight: .medium))
      Text("Redacted preview").font(.pip(size: 12, weight: .semibold))
      ScrollView {
        Text(SensitiveInfo.redacted(text)).font(.pip(size: 12, design: .monospaced))
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
      }.frame(minHeight: 110, maxHeight: 230).background(
        p.quiet, in: RoundedRectangle(cornerRadius: 10))
      Text(
        "Pattern detection can miss private information or mark harmless text. It is a hint, not a complete privacy check."
      )
      .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
      HStack {
        Button(copied ? "Copied redacted text" : "Copy redacted text") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(SensitiveInfo.redacted(text), forType: .string)
          copied = true
        }.buttonStyle(QuietButtonStyle())
        Spacer()
        Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(
          .defaultAction)
      }
    }.padding(30).frame(width: 570).background(p.panel).foregroundStyle(p.ink)
      .onExitCommand { dismiss() }
  }
}
