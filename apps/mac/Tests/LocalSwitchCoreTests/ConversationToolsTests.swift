import XCTest

@testable import LocalSwitchCore

final class ConversationToolsTests: XCTestCase {
  func testSearchCoversAllChatsAndContentFieldsInStableOrder() {
    let conversations = (0..<18).map { index in
      SavedConversation(
        id: UUID(),
        messages: [ChatMessage(role: "user", content: "Message \(index)")],
        draft: index == 16 ? "Needle in draft" : nil
      )
    }
    var titleMatch = SavedConversation(
      id: UUID(), messages: [ChatMessage(role: "user", content: "First")])
    titleMatch.title = "Needle in title"
    var bodyMatch = SavedConversation(
      id: UUID(), messages: [ChatMessage(role: "assistant", content: "Needle in body")])
    bodyMatch.title = "Body result"
    let ordered = [titleMatch] + conversations + [bodyMatch]

    let results = ConversationTools.matching(ordered, query: "needle")

    XCTAssertEqual(results.map(\.id), [titleMatch.id, conversations[16].id, bodyMatch.id])
    XCTAssertEqual(
      ConversationTools.matching(ordered, query: "  \n\t").map(\.id), ordered.map(\.id))
  }

  func testCancelledSearchDoesNotProduceResults() async {
    let chats = [
      SavedConversation(id: UUID(), messages: [ChatMessage(role: "user", content: "Needle")])
    ]
    let task = Task {
      try? await Task.sleep(for: .seconds(30))
      return ConversationTools.matching(chats, query: "Needle")
    }
    task.cancel()
    let result = await task.value
    XCTAssertTrue(result.isEmpty)
  }

  func testSearchIsCaseAndDiacriticInsensitiveForUnicode() {
    let chat = SavedConversation(
      id: UUID(),
      messages: [ChatMessage(role: "assistant", content: "Café déjà vu — Καλημέρα")])

    XCTAssertEqual(ConversationTools.matching([chat], query: "CAFE").map(\.id), [chat.id])
    XCTAssertEqual(ConversationTools.matching([chat], query: "DEJA").map(\.id), [chat.id])
    XCTAssertEqual(ConversationTools.matching([chat], query: "καλημέρα").map(\.id), [chat.id])
  }

  func testSearchDoesNotMatchEditionIdentityOrProviderMetadata() {
    let chat = SavedConversation(
      id: UUID(),
      messages: [
        ChatMessage(
          role: "assistant", content: "Ordinary answer", route: "private-provider-token",
          model: "secret-model-name", outboundDigest: "digest-only")
      ])

    XCTAssertTrue(ConversationTools.matching([chat], query: "private-provider-token").isEmpty)
    XCTAssertTrue(ConversationTools.matching([chat], query: "secret-model-name").isEmpty)
    XCTAssertTrue(ConversationTools.matching([chat], query: "digest-only").isEmpty)
    XCTAssertTrue(ConversationTools.matching([chat], query: chat.id.uuidString).isEmpty)
  }

  func testSearchIgnoresHiddenSystemAndToolMessageText() {
    let chat = SavedConversation(
      id: UUID(),
      messages: [
        ChatMessage(role: "system", content: "hidden-search-token"),
        ChatMessage(role: "tool", content: "hidden-search-token"),
      ])

    XCTAssertTrue(ConversationTools.matching([chat], query: "hidden-search-token").isEmpty)
  }

  func testMarkdownExportsOnlyVisibleTurnsAndSelectedDraftAsLiteralText() {
    let body = "Exact 👋🏽 text\n```swift\nprint(\"hello\")\n```\n<script>alert(1)</script>"
    let draft = "Unsent 東京\n````\n<em>literal</em>"
    let markdown = ConversationTools.markdown(
      title: "A # title\nwith controls\u{0007}",
      messages: [
        ChatMessage(role: "user", content: "Question"),
        ChatMessage(
          role: "assistant", content: body, state: "stopped", route: "private-provider-token",
          model: "secret-model-name", outboundDigest: "digest-only"),
        ChatMessage(role: "system", content: "hidden system instructions"),
        ChatMessage(role: "tool", content: "hidden tool result"),
      ], draft: draft)

    XCTAssertTrue(markdown.hasPrefix("# A \\# title with controls\n"))
    XCTAssertTrue(markdown.contains("## You · Message"))
    XCTAssertTrue(markdown.contains("## Assistant · Route not recorded · Stopped · partial"))
    XCTAssertTrue(markdown.contains(body))
    XCTAssertTrue(markdown.contains(draft))
    XCTAssertTrue(markdown.contains("## Draft (not sent)"))
    XCTAssertFalse(markdown.contains("hidden system instructions"))
    XCTAssertFalse(markdown.contains("hidden tool result"))
    XCTAssertFalse(markdown.contains("private-provider-token"))
    XCTAssertFalse(markdown.contains("secret-model-name"))
    XCTAssertFalse(markdown.contains("digest-only"))
    XCTAssertTrue(markdown.contains("````\n\(body)\n````"))
    XCTAssertTrue(markdown.contains("`````\n\(draft)\n`````"))
  }

  func testMarkdownUsesOnlySelectedConversationInputsAndKeepsExactMessageText() {
    let selected = [
      ChatMessage(role: "user", content: "Chosen content — café"),
      ChatMessage(role: "assistant", content: "Local answer", route: "local"),
      ChatMessage(role: "assistant", content: "Cloud answer", route: "chatgpt"),
    ]
    let markdown = ConversationTools.markdown(title: "Chosen", messages: selected, draft: "")

    XCTAssertTrue(markdown.contains("Chosen content — café"))
    XCTAssertFalse(markdown.contains("Another chat"))
    XCTAssertFalse(markdown.contains("registered client"))
    XCTAssertFalse(markdown.contains("account credentials"))
    XCTAssertFalse(markdown.contains("## Draft (not sent)"))
    XCTAssertTrue(markdown.contains("## Pip · On this Mac · Complete"))
    XCTAssertTrue(markdown.contains("## ChatGPT · Cloud · Complete"))
  }
}
