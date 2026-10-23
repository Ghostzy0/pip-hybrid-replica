import AppKit
import LocalSwitchCore
import SwiftUI

/// Selectable plain text only. Message content cannot load images, run HTML or open remote resources.
struct ChatMessageRow: View {
  let message: ChatMessage
  let completionID: UUID?
  @Environment(\.colorScheme) private var scheme
  private var isAssistant: Bool { message.role == "assistant" }
  private var isStreaming: Bool { message.state == "streaming" }
  private var name: String {
    isAssistant ? (message.route == "chatgpt" ? "ChatGPT" : "Pip") : "You"
  }
  private var detail: String {
    if !isAssistant {
      return message.redactedForCloud == true
        ? "Local original · reviewed with redaction" : "Your message"
    }
    let route = message.route == "chatgpt" ? "ChatGPT cloud" : "On this Mac"
    let state: String
    switch message.state {
    case "streaming": state = "Writing"
    case "complete": state = "Complete"
    case "stopped": state = "Stopped"
    case "interrupted": state = "Interrupted"
    case "error", "failed": state = "Couldn’t finish"
    default: state = message.state.capitalized
    }
    return "\(route) · \(state)"
  }
  private var placeholder: String {
    if isStreaming {
      return message.route == "chatgpt"
        ? "Preparing the ChatGPT response…" : "Preparing the local model…"
    }
    return isAssistant ? "No response text was returned." : "Empty message."
  }
  var body: some View {
    let p = SwitchPalette(scheme)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 9) {
        if isAssistant {
          PipView(
            size: 27, working: isStreaming, completionID: completionID,
            live: isStreaming || completionID != nil)
        } else {
          Image(systemName: "person.crop.circle").font(.pip(size: 22)).foregroundStyle(
            p.secondary
          )
          .frame(width: 27, height: 27).accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(name).font(.pip(size: 12, weight: .semibold))
          Text(detail).font(.pip(size: 10)).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 2)
        Spacer(minLength: 6)
        if !message.content.isEmpty {
          ChatCopyButton(
            text: message.content,
            noun: isAssistant ? (isStreaming ? "partial response" : "response") : "message")
        }
      }
      Text(verbatim: message.content.isEmpty ? placeholder : message.content)
        .font(.pip(size: isAssistant ? 15 : 14)).lineSpacing(isAssistant ? 6 : 5)
        .foregroundStyle(isAssistant ? p.ink : p.canvas)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
          isAssistant ? p.quiet : p.ink,
          in: RoundedRectangle(cornerRadius: 20))
    }
    .accessibilityElement(children: .contain)
  }
}

/// Feedback confirms the actual pasteboard write. A replaced/removed button cancels its finite reset.
private struct ChatCopyButton: View {
  let text: String
  let noun: String
  @Environment(\.colorScheme) private var scheme
  @State private var outcome: Bool?
  @State private var feedbackID: UUID?
  @State private var copiedNoun: String?
  private var title: String {
    outcome == true ? "Copied" : (outcome == false ? "Retry copy" : "Copy")
  }
  private var image: String {
    outcome == true ? "checkmark" : (outcome == false ? "exclamationmark.circle" : "doc.on.doc")
  }
  private var captureOnly: Bool {
    let args = ProcessInfo.processInfo.arguments
    return args.contains("--qa-output") && args.contains("--qa-screen")
  }
  var body: some View {
    let p = SwitchPalette(scheme)
    Button(action: copy) {
      Label(title, systemImage: image).font(.pip(size: 10, weight: .medium))
        .frame(minWidth: 68, alignment: .trailing).padding(.vertical, 5).padding(.horizontal, 6)
        .contentShape(Rectangle())
    }.buttonStyle(.plain).foregroundStyle(outcome == false ? p.error : p.secondary)
      .accessibilityLabel(
        outcome == true ? "\((copiedNoun ?? noun).capitalized) copied" : "Copy \(noun)"
      )
      .accessibilityHint(
        outcome == false
          ? "Copy failed. Try again or select the text to copy it."
          : "Copies the text currently shown"
      )
      .help(
        outcome == false ? "Copy failed. You can also select and copy the text." : "Copy \(noun)"
      )
      .task(id: feedbackID) {
        guard let ticket = feedbackID else { return }
        do {
          try await Task.sleep(nanoseconds: 2_500_000_000)
          guard !Task.isCancelled, feedbackID == ticket else { return }
          outcome = nil
          copiedNoun = nil
        } catch {
          // A newer copy or disappearing row owns its own feedback.
        }
      }
      .onDisappear {
        feedbackID = nil
        outcome = nil
        copiedNoun = nil
      }
  }
  private func copy() {
    let board =
      captureOnly
      ? NSPasteboard(
        name: NSPasteboard.Name(
          "app.pip.hybrid.mac.qa.copy.\(ProcessInfo.processInfo.processIdentifier)"))
      : NSPasteboard.general
    board.clearContents()
    let copied = board.setString(text, forType: .string)
    outcome = copied
    copiedNoun = noun
    feedbackID = UUID()
    if !captureOnly, let application = NSApp {
      NSAccessibility.post(
        element: application, notification: .announcementRequested,
        userInfo: [
          .announcement: copied
            ? "\(noun.capitalized) copied" : "Copy failed. Select the text to copy it.",
          .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
  }
}
