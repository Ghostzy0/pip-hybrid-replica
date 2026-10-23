import LocalSwitchCore
import SwiftUI

struct DeviceView: View {
  let device: DeviceSnapshot
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let p = SwitchPalette(scheme)
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Meet the machine.").font(.pip(size: 33, weight: .semibold))
            .tracking(-0.6)
          Text(
            "Real hardware facts, read locally. No serial numbers or device identifiers collected."
          )
          .font(.pip(size: 13)).foregroundStyle(p.secondary)
        }
        HStack(alignment: .center, spacing: 26) {
          ZStack {
            RoundedRectangle(cornerRadius: 20).fill(p.quiet).frame(width: 110, height: 110)
            Image(systemName: "desktopcomputer").font(.pip(size: 45, weight: .ultraLight))
          }.accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 9) {
            Text(device.chip).font(.pip(size: 23, weight: .semibold))
            Text("\(device.architecture) · \(device.cpuCount) CPU cores")
              .font(.pip(size: 13)).foregroundStyle(p.secondary)
            StatusPill(
              title: device.unifiedMemory
                ? "Unified memory architecture" : "Separate memory architecture",
              systemImage: "memorychip")
          }
        }
        VStack(spacing: 0) {
          fact(
            "Physical memory",
            value: String(format: "%.0f GiB", Double(device.physicalMemory) / 1_073_741_824))
          Divider().overlay(p.border)
          fact("GPU", value: device.gpuName)
          Divider().overlay(p.border)
          fact(
            "Metal working-set recommendation",
            value: device.recommendedWorkingSet > 0
              ? String(format: "%.1f GiB", Double(device.recommendedWorkingSet) / 1_073_741_824)
              : "Unavailable")
        }.padding(.horizontal, 20).background(
          p.quiet.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        VStack(alignment: .leading, spacing: 9) {
          Label(
            device.unifiedMemory
              ? "One memory pool. Counted once." : "Memory stays in its own pool.",
            systemImage: "info.circle"
          )
          .font(.pip(size: 13, weight: .medium))
          Text(
            device.unifiedMemory
              ? "Your CPU and GPU share the same physical memory. Pip Hybrid doesn't add GPU memory on top of RAM. Model estimates also leave space for macOS, context and the runtime."
              : "Physical RAM and GPU budgets are separate facts. Pip Hybrid uses a conservative fit estimate and doesn't add shared GPU memory to physical RAM."
          )
          .font(.pip(size: 12)).foregroundStyle(p.secondary).lineSpacing(4)
          Text(
            "These are hardware facts and estimates, not a live memory-pressure monitor. Close heavy apps if model loading fails."
          )
          .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
        }
      }.padding(37).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
    }
  }
  private func fact(_ label: String, value: String) -> some View {
    HStack(alignment: .top, spacing: 20) {
      Text(label).foregroundStyle(SwitchPalette(scheme).secondary)
      Spacer()
      Text(value).fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
    }.font(.pip(size: 12)).padding(.vertical, 18)
  }
}

struct PreferencesView: View {
  @ObservedObject var app: AppModel
  @AppStorage("pipMotionPaused", store: PipAppIdentity.preferences)
  private var pipPaused = false
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let p = SwitchPalette(scheme)
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          VStack(alignment: .leading, spacing: 10) {
            Text("Make yourself at home.").font(.pip(size: 33, weight: .semibold))
              .tracking(-0.6)
            Text("A small set of choices. The important boundaries stay visible.")
              .font(.pip(size: 13)).foregroundStyle(p.secondary)
          }
          VStack(alignment: .leading, spacing: 15) {
            Text("Appearance").font(.pip(size: 14, weight: .semibold))
            Picker("Appearance", selection: $app.appearance) {
              Text("System").tag("system")
              Text("Light").tag("light")
              Text("Dark").tag("dark")
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            Text("Motion follows macOS Reduce Motion automatically.")
              .font(.pip(size: 11)).foregroundStyle(p.secondary)
            Toggle("Pause Pip", isOn: $pipPaused).toggleStyle(.switch)
              .font(.pip(size: 13))
            Text("Keep Pip still. Your work continues.")
              .font(.pip(size: 12)).foregroundStyle(p.secondary)
          }
          Divider().overlay(p.border)
          VStack(alignment: .leading, spacing: 13) {
            Text("Your choice stays explicit").font(.pip(size: 14, weight: .semibold))
            Text(
              "Local only sends messages to the inference engine on this Mac. Model downloads connect to the publisher. Optional ChatGPT requests use the cloud only after you choose that route and approve its exact outgoing conversation. There is no automatic cloud fallback or web search."
            )
            .font(.pip(size: 12)).foregroundStyle(p.secondary).lineSpacing(4)
            Text(
              "History, titles and drafts are encrypted with AES-256-GCM. The encryption key stays in your Mac login Keychain. Keep your macOS account and backups protected; losing the key can make saved chats unrecoverable."
            )
            .font(.pip(size: 12)).foregroundStyle(p.secondary).lineSpacing(4)
            Label(app.historySummary, systemImage: app.historyAvailable ? "lock.shield" : "lock")
              .font(.pip(size: 12, weight: .medium))
            if let notice = app.historyNotice {
              Text(notice).font(.pip(size: 12)).foregroundStyle(p.error).textSelection(.enabled)
              HStack {
                Button("Unlock history", action: app.retryHistoryAccess).disabled(app.isBusy)
                  .buttonStyle(
                    QuietButtonStyle())
                Button("Use temporary session", action: app.useTemporarySession).disabled(
                  app.isBusy
                ).buttonStyle(
                  QuietButtonStyle())
              }
            }
            if app.temporarySession {
              Text("This session is not saved. Starting a new chat clears its unsaved text.").font(
                .system(size: 11)
              ).foregroundStyle(p.secondary)
            }
            Button("Unload local model", action: app.unload).buttonStyle(QuietButtonStyle())
              .disabled(
                app.isBusy)
            Text(
              "Unload releases the owned inference process. Your model file and conversations remain."
            )
            .font(.pip(size: 11)).foregroundStyle(p.secondary)
          }
          Divider().overlay(p.border)
          VStack(alignment: .leading, spacing: 17) {
            Text("AI providers").font(.pip(size: 14, weight: .semibold))
            Text(
              "Local chat works without signing in. Connect ChatGPT below for optional, reviewed cloud requests. Other providers need their own supported integrations."
            )
            .font(.pip(size: 12)).foregroundStyle(p.secondary).lineSpacing(4)
            ChatGPTAccountsView(app: app, connection: app.chatGPT).id("chatgpt-accounts")
            provider(
              "Claude", status: "Approval required",
              detail: "Third-party subscription sign-in requires Anthropic approval.",
              url: "https://code.claude.com/docs/en/agent-sdk/overview")
            provider(
              "OpenCode Go", status: "Compatibility review",
              detail:
                "A subscription key route exists; general-chat eligibility still needs review.",
              url: "https://opencode.ai/docs/go/")
            provider(
              "Google Antigravity", status: "Unavailable",
              detail:
                "Consumer Antigravity does not support third-party app wrappers. Gemini API is a separate optional route.",
              url: "https://antigravity.google/docs/faq")
          }
          Divider().overlay(p.border)
          HStack(alignment: .top, spacing: 16) {
            PipView(size: 47, greeting: true)
            VStack(alignment: .leading, spacing: 8) {
              Text("A little company. Plenty of space.").font(.pip(size: 14, weight: .medium))
              Text(
                "Pip keeps you company while you work. A quiet glance, then space to think. You can pause Pip whenever you like."
              )
              .font(.pip(size: 12)).foregroundStyle(p.secondary).lineSpacing(3)
              Text("Pip Hybrid 0.1 · Mac alpha · MIT licensed")
                .font(.pip(size: 10, design: .monospaced)).foregroundStyle(p.secondary)
            }
          }
        }.padding(37).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
      }
      .onAppear {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--qa-output"), args.contains("--qa-accounts") {
          DispatchQueue.main.async { proxy.scrollTo("chatgpt-accounts", anchor: .top) }
        }
      }
    }
  }
  private func provider(_ title: String, status: String, detail: String, url: String) -> some View {
    let p = SwitchPalette(scheme)
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title).font(.pip(size: 12, weight: .semibold))
        Spacer()
        Text(status).font(.pip(size: 10)).foregroundStyle(p.secondary)
      }
      Text(detail).font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
      if let destination = URL(string: url) {
        Link("Provider documentation", destination: destination).font(.pip(size: 10))
      }
    }.padding(15).background(p.quiet.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
  }

}
