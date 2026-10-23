import Foundation

/// Local, in-memory helpers for finding and exporting saved conversations.
public enum ConversationTools {
  /// Returns conversations containing `query` in their title, message text, or draft.
  /// The input order is preserved, and no identifiers or provider metadata are searched.
  public static func matching(
    _ conversations: [SavedConversation], query: String
  ) -> [SavedConversation] {
    guard !Task.isCancelled else { return [] }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return conversations }
    let foldedNeedle = fold(needle)

    return conversations.filter { conversation in
      guard !Task.isCancelled else { return false }
      if fold(conversation.title).contains(foldedNeedle) { return true }
      if conversation.messages.contains(where: {
        !Task.isCancelled && ($0.role == "user" || $0.role == "assistant")
          && fold($0.content).contains(foldedNeedle)
      }) {
        return true
      }
      if let draft = conversation.draft, fold(draft).contains(foldedNeedle) { return true }
      return false
    }
  }

  /// Produces a plaintext transcript for one explicitly selected conversation.
  /// Message bodies are fenced as literal text so Markdown and HTML remain inert.
  public static func markdown(title: String, messages: [ChatMessage], draft: String) -> String {
    var sections = ["# \(safeHeading(title))"]

    for message in messages {
      let heading: String
      switch message.role {
      case "user":
        heading = "You · Message"
      case "assistant":
        let speaker: String
        switch message.route {
        case .some("local"): speaker = "Pip · On this Mac"
        case .some("chatgpt"): speaker = "ChatGPT · Cloud"
        default: speaker = "Assistant · Route not recorded"
        }
        heading = "\(speaker) · \(visibleState(message.state))"
      default:
        // System/tool records are not part of the user-visible transcript.
        continue
      }
      sections.append("## \(heading)\n\n\(literalBlock(message.content))")
    }

    if !draft.isEmpty {
      sections.append("## Draft (not sent)\n\n\(literalBlock(draft))")
    }

    return sections.joined(separator: "\n\n") + "\n"
  }

  private static func fold(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  private static func visibleState(_ state: String) -> String {
    switch state {
    case "streaming": return "Writing · partial"
    case "complete": return "Complete"
    case "stopped": return "Stopped · partial"
    case "interrupted": return "Interrupted · partial"
    case "error", "failed": return "Couldn’t finish · partial"
    default: return "Saved"
    }
  }

  private static func safeHeading(_ title: String) -> String {
    let reserved = CharacterSet(charactersIn: "\\`*_{}[]()#+-.!|<>~")
    let scalars = title.unicodeScalars.compactMap { scalar -> String? in
      if scalar == "\n" || scalar == "\r" || scalar == "\t" { return " " }
      if CharacterSet.controlCharacters.contains(scalar) { return nil }
      let value = String(scalar)
      return reserved.contains(scalar) ? "\\" + value : value
    }
    let cleaned = scalars.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Untitled chat" : cleaned
  }

  private static func literalBlock(_ content: String) -> String {
    let longestBacktickRun = longestRun(of: "`", in: content)
    let fence = String(repeating: "`", count: max(3, longestBacktickRun + 1))
    return "\(fence)\n\(content)\n\(fence)"
  }

  private static func longestRun(of character: Character, in value: String) -> Int {
    var longest = 0
    var current = 0
    for item in value {
      if item == character {
        current += 1
        longest = max(longest, current)
      } else {
        current = 0
      }
    }
    return longest
  }
}
