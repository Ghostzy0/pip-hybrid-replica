import CryptoKit
import Foundation
import LocalSwitchCore
import SwiftUI

/// Immutable consent snapshot. Credentials are never part of this value or its visible JSON.
struct CloudReview: Identifiable {
  let id = UUID()
  let accountID: String
  let subject: String
  let accountLabel: String
  let model: String
  let modelName: String
  let messages: [RuntimeMessage]
  let sourceFingerprint: String
  let redacted: Bool
  let body: Data
  let digest: String
  init(
    accountID: String, subject: String, accountLabel: String, model: String, modelName: String,
    messages: [RuntimeMessage], sourceFingerprint: String, redacted: Bool
  ) throws {
    self.accountID = accountID
    self.subject = subject
    self.accountLabel = accountLabel
    self.model = model
    self.modelName = modelName
    self.messages = messages
    self.sourceFingerprint = sourceFingerprint
    self.redacted = redacted
    body = try ChatGPTResponseParser.requestBody(model: model, messages: messages)
    digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
  }
  var findings: Int { messages.reduce(0) { $0 + SensitiveInfo.scan($1.content).count } }
}

struct CloudReviewHost: ViewModifier {
  @ObservedObject var app: AppModel
  func body(content: Content) -> some View {
    content
      .sheet(item: $app.pendingCloudReview) { review in CloudReviewView(app: app, review: review) }
      .alert("You’re using your ChatGPT plan", isPresented: $app.chatGPTWelcome) {
        Button("Got it", action: app.dismissChatGPTWelcome)
      } message: {
        Text(
          "Eligible cloud requests use your selected ChatGPT account and its plan limits. Local only stays on until you choose ChatGPT. Review each outgoing conversation before sending. Manage limits and any provider credit permissions in ChatGPT settings."
        )
      }
  }
}

private struct CloudReviewView: View {
  @ObservedObject var app: AppModel
  let review: CloudReview
  @Environment(\.colorScheme) private var scheme
  @State private var showJSON = false
  var body: some View {
    let p = SwitchPalette(scheme)
    VStack(alignment: .leading, spacing: 17) {
      HStack(spacing: 13) {
        Image(systemName: "arrow.up.right.circle").font(.pip(size: 29, weight: .light))
        VStack(alignment: .leading, spacing: 5) {
          Text("A moment before this leaves your Mac.").font(.pip(size: 23, design: .serif))
          Text("ChatGPT · \(review.modelName)").font(.pip(size: 12, weight: .medium))
        }
      }
      Text(review.accountLabel).font(.pip(size: 11)).foregroundStyle(p.secondary)
        .textSelection(.enabled)
      Text(
        "This sends all text below to OpenAI, including earlier local messages and the assistant instructions. It uses your ChatGPT plan. Provider retention and usage policies still apply; store: false does not guarantee zero retention."
      )
      .font(.pip(size: 12)).foregroundStyle(p.secondary).lineSpacing(4)
      HStack {
        Label(
          review.redacted
            ? "Pattern redaction applied" : "\(review.findings) possible sensitive \(review.findings == 1 ? "item" : "items")",
          systemImage: review.redacted ? "eye.slash" : "eye")
        Spacer()
        if !review.redacted && review.findings > 0 {
          Button("Redact patterns & review") { app.prepareCloudReview(redacted: true) }
            .buttonStyle(.link)
        }
      }.font(.pip(size: 11))
      Text(
        "Pattern hints can miss private information. Read the whole conversation before sending."
      )
      .font(.pip(size: 10)).foregroundStyle(p.secondary)
      Picker("Review format", selection: $showJSON) {
        Text("Conversation").tag(false)
        Text("Exact request JSON").tag(true)
      }.pickerStyle(.segmented).frame(maxWidth: 340)
      ScrollView {
        if showJSON {
          Text(String(decoding: review.body, as: UTF8.self))
            .font(.pip(size: 11, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(15)
        } else {
          LazyVStack(alignment: .leading, spacing: 19) {
            ForEach(Array(review.messages.enumerated()), id: \.offset) { _, item in
              VStack(alignment: .leading, spacing: 7) {
                Text(item.role == "system" ? "Assistant instructions" : item.role.capitalized)
                  .font(.pip(size: 11, weight: .semibold)).foregroundStyle(p.secondary)
                Text(item.content).font(.pip(size: 12)).lineSpacing(4).textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }.padding(16)
        }
      }.frame(minHeight: 150, maxHeight: 300).background(
        p.quiet, in: RoundedRectangle(cornerRadius: 10))
      HStack {
        Button("Back to draft") { app.pendingCloudReview = nil }.buttonStyle(QuietButtonStyle())
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Send to ChatGPT") { app.approveCloudReview(review) }.buttonStyle(
          PrimaryButtonStyle()
        )
        .disabled(!app.canSend || app.isBusy)
      }
    }.padding(28).frame(width: 650).background(p.panel).foregroundStyle(p.ink)
  }
}
