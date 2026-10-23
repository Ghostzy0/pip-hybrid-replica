import LocalSwitchCore
import SwiftUI

/// Only connection metadata is displayed here. No credential or authorisation URL enters a label.
struct ChatGPTAccountsView: View {
  @ObservedObject var app: AppModel
  @ObservedObject var connection: ChatGPTConnection
  @Environment(\.colorScheme) private var scheme
  private var controlsDisabled: Bool {
    app.isBusy || app.isManagingChatGPT || connection.isAuthorizing || connection.isRenewingSession
  }
  var body: some View {
    let p = SwitchPalette(scheme)
    VStack(alignment: .leading, spacing: 17) {
      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 7) {
          Text("Use your ChatGPT plan").font(.pip(size: 15, weight: .semibold))
          Text(
            "Connect an eligible ChatGPT account for optional cloud conversations. Local chat stays available without an account."
          )
          .font(.pip(size: 12)).foregroundStyle(p.secondary).lineSpacing(3)
        }
        Spacer(minLength: 4)
        Image(systemName: "person.crop.circle.badge.checkmark").font(
          .system(size: 24, weight: .light)
        )
        .foregroundStyle(p.secondary).accessibilityHidden(true)
      }
      if !connection.accounts.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Picker(
            "ChatGPT account",
            selection: Binding(
              get: { connection.activeAccountID ?? "" }, set: { app.selectChatGPTAccount($0) })
          ) {
            Text("Choose a saved account").tag("")
            ForEach(connection.accounts) { account in Text(account.label).tag(account.id) }
          }.disabled(controlsDisabled)
          Text(
            "Each saved registration is separate, even when email addresses match. Its short label distinguishes saved sign-ins. ChatGPT controls workspace access and plan permission."
          )
          .font(.pip(size: 10)).foregroundStyle(p.secondary).fixedSize(
            horizontal: false, vertical: true)
        }
      }
      if let account = connection.activeAccount {
        VStack(alignment: .leading, spacing: 8) {
          Text(account.displayName).font(.pip(size: 13, weight: .medium)).textSelection(.enabled)
          if let email = account.email, email != account.displayName {
            Text(email).font(.pip(size: 11)).foregroundStyle(p.secondary).textSelection(.enabled)
          }
          Label(
            account.isSignedIn
              ? (account.planEnabled
                ? "Plan permission enabled" : "Signed in · plan usage not enabled")
              : "Saved account · signed out",
            systemImage: account.isSignedIn && account.planEnabled
              ? "checkmark.shield" : "person.crop.circle"
          )
          .font(.pip(size: 11, weight: .medium)).foregroundStyle(p.secondary)
          if account.isSignedIn && !account.planEnabled {
            Text(
              "Identity sign-in alone cannot use your ChatGPT plan. Continue with ChatGPT to review access, or manage this app in ChatGPT settings."
            )
            .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
          }
        }
      }
      if connection.isAuthorizing {
        VStack(alignment: .leading, spacing: 11) {
          Label("Waiting for you in the browser", systemImage: "safari").font(
            .system(size: 12, weight: .medium))
          Text(
            "Complete ChatGPT sign-in and review its permissions. Cancelling keeps any existing account connection."
          )
          .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) { pendingActions }
            VStack(alignment: .leading, spacing: 9) { pendingActions }
          }
        }.padding(14).background(p.raised, in: RoundedRectangle(cornerRadius: 10))
      } else if !connection.protectedStorageAvailable {
        VStack(alignment: .leading, spacing: 10) {
          Text("ChatGPT credentials are locked").font(.pip(size: 12, weight: .medium))
          Text(
            "Unlock protected storage to continue. Pip Hybrid will not replace credentials it cannot open."
          )
          .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
          Button("Unlock Keychain & retry", action: app.retryChatGPTAccess).buttonStyle(
            QuietButtonStyle()
          ).disabled(controlsDisabled)
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 9) { connectionActions }
          VStack(alignment: .leading, spacing: 9) { connectionActions }
        }
      }
      if connection.activeAccount?.isSignedIn == true
        && connection.activeAccount?.planEnabled == true
      {
        VStack(alignment: .leading, spacing: 9) {
          if !connection.models.isEmpty {
            Picker("ChatGPT model", selection: $app.selectedChatGPTModel) {
              Text("Choose an available model").tag("")
              ForEach(connection.models) { model in Text(model.displayName).tag(model.slug) }
            }.disabled(controlsDisabled)
          } else {
            Text(
              "No account model choices are loaded. Refresh the catalogue to check what this registration can use."
            )
            .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
          }
          Button("Refresh models", action: app.refreshChatGPTModels).buttonStyle(.link).font(
            .system(size: 11)
          ).disabled(controlsDisabled)
        }
      }
      if connection.activeAccount?.isSignedIn == true {
        sessionControls(p)
      }
      if let action = app.chatGPTManagementAction {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(action).font(.pip(size: 11)).foregroundStyle(p.secondary)
        }.accessibilityElement(children: .combine)
      }
      if let confirmed = connection.lastRemoteRevocationConfirmed {
        Label(
          confirmed ? "Remote session sign-out confirmed" : "Remote sign-out was not confirmed",
          systemImage: confirmed ? "checkmark.shield" : "exclamationmark.triangle"
        )
        .font(.pip(size: 11)).foregroundStyle(confirmed ? p.secondary : p.error)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(connection.status).font(.pip(size: 11, weight: .medium)).foregroundStyle(
          p.secondary
        ).textSelection(.enabled)
        if let message = connection.error {
          Label(message, systemImage: "exclamationmark.triangle").font(.pip(size: 11))
            .foregroundStyle(p.error)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
      }
      Divider().overlay(p.border)
      Text(
        "Signing in does not switch Local only off or send a chat. Choose ChatGPT explicitly, then review the exact outgoing conversation before each cloud request."
      )
      .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
      Text(
        "Eligible requests use your ChatGPT plan and its limits. Review whether provider credits are allowed in ChatGPT settings. Pip Hybrid never falls back to separately billed API access."
      )
      .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
      Link("Manage ChatGPT usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
        .font(.pip(size: 11))
    }.padding(17).background(p.quiet.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
      .accessibilityElement(children: .contain)
  }
  private func sessionControls(_ p: SwitchPalette) -> some View {
    TimelineView(.periodic(from: .now, by: 30)) { _ in
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Session access").font(.pip(size: 12, weight: .medium))
          Spacer()
          Button(
            connection.isRenewingSession ? "Renewing…" : "Renew session",
            action: app.renewChatGPTSession
          )
          .buttonStyle(.link).font(.pip(size: 11))
          .disabled(controlsDisabled || !connection.canRenewSession)
        }
        if let renewed = connection.lastSessionRenewalAt {
          Text(
            "Renewed \(renewed.formatted(date: .omitted, time: .standard)). Replacement credentials saved in Keychain."
          )
          .font(.pip(size: 10)).foregroundStyle(p.secondary)
        } else if let expiry = connection.activeAccount?.expiresAt {
          Text(
            "Current access expires \(expiry.formatted(date: .abbreviated, time: .shortened)). Pip Hybrid renews it when needed."
          )
          .font(.pip(size: 10)).foregroundStyle(p.secondary)
        }
        if let next = connection.nextSessionRenewalAt, next > Date() {
          Text(
            "OpenAI allows renewal after \(next.formatted(date: .abbreviated, time: .standard))."
          )
          .font(.pip(size: 10)).foregroundStyle(p.secondary)
        }
        Text(
          "Renewal updates this saved session without sending a chat. It never changes Local only or the billing route."
        )
        .font(.pip(size: 10)).foregroundStyle(p.secondary).fixedSize(
          horizontal: false, vertical: true)
      }.padding(12).background(p.raised, in: RoundedRectangle(cornerRadius: 10))
    }
  }
  @ViewBuilder private var pendingActions: some View {
    Button("Open sign-in page", action: app.openChatGPTSignInPage).buttonStyle(QuietButtonStyle())
    Button("Cancel sign-in", action: app.cancelChatGPTSignIn).buttonStyle(.bordered)
  }
  @ViewBuilder private var connectionActions: some View {
    if connection.activeAccount?.isSignedIn != true || connection.activeAccount?.planEnabled != true
    {
      Button("Continue with ChatGPT") {
        app.startChatGPTSignIn(accountID: connection.activeAccountID)
      }
      .buttonStyle(ChatGPTContinueStyle()).disabled(controlsDisabled)
    }
    if !connection.accounts.isEmpty {
      Button("Add account or workspace") { app.startChatGPTSignIn(accountID: nil) }
        .buttonStyle(QuietButtonStyle()).disabled(controlsDisabled)
    }
    if connection.activeAccount?.isSignedIn == true {
      Button("Sign out", action: app.disconnectChatGPT).buttonStyle(.bordered).disabled(
        app.isBusy || app.isSigningOutChatGPT)
    }
  }
}

private struct ChatGPTContinueStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @Environment(\.colorScheme) private var scheme
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.pip(size: 12, weight: .semibold))
      .padding(.horizontal, 15).padding(.vertical, 11)
      .foregroundStyle(scheme == .dark ? Color.black : Color.white)
      .background(
        (scheme == .dark ? Color.white : Color.black).opacity(
          enabled ? (configuration.isPressed ? 0.78 : 1) : 0.45),
        in: RoundedRectangle(cornerRadius: 8))
  }
}
