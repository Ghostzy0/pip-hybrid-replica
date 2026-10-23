import LocalSwitchCore
import SwiftUI

struct OnboardingView: View {
  @ObservedObject var app: AppModel
  @ObservedObject var models: ModelStore
  var explore: () -> Void
  @State private var step = 0
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduced
  @AccessibilityFocusState private var headingFocus: Int?

  private let stepNames = ["Your space", "This Mac", "Local model"]
  private var starterModels: [ModelDescriptor] { Array(ModelDescriptor.catalogue.prefix(2)) }
  private var supportedStarter: Bool { starterModels.contains { $0.fits(app.device) } }
  private var unsupportedHardwareReason: String? {
    if app.device.architecture != "arm64" {
      return "The local engine needs an Apple Silicon Mac. You can explore without downloading."
    }
    if !app.device.unifiedMemory {
      return "A supported unified-memory GPU wasn't detected. You can explore without downloading."
    }
    if app.device.recommendedWorkingSet == 0 {
      return
        "A supported Metal memory budget couldn't be read. Local downloads stay unavailable until it can be checked."
    }
    return nil
  }
  private var activeDownload: Bool {
    ["downloading", "paused", "verifying"].contains(models.phase)
  }

  var body: some View {
    let p = SwitchPalette(scheme)
    VStack(spacing: 0) {
      HStack(spacing: 20) {
        HStack(spacing: 8) {
          PipView(size: 27, live: false)
          Text("Pip Hybrid").font(.pip(size: 13, weight: .semibold))
        }
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 8) {
          Text("\(step + 1) of 3 · \(stepNames[step])")
            .font(.pip(size: 11, weight: .medium)).foregroundStyle(p.secondary)
          HStack(spacing: 5) {
            ForEach(0..<3) { index in
              Capsule().fill(index == step ? p.ink : p.border).frame(
                width: index == step ? 22 : 7, height: 5)
            }
          }.accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup step \(step + 1) of 3: \(stepNames[step])")
      }.padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 14)

      ScrollViewReader { scroll in
        ScrollView {
          VStack(spacing: 22) {
            Color.clear.frame(height: 0).id("setup-top")
            if step == 0 {
              introduction(p)
            } else if step == 1 {
              hardware(p)
            } else {
              chooseModel(p)
            }
          }
          .frame(maxWidth: step == 2 ? 800 : 650)
          .padding(.horizontal, 30).padding(.top, 14).padding(.bottom, 26)
          .frame(maxWidth: .infinity)
        }
        .onChange(of: step) { _, _ in
          // A new setup step starts at its heading, even if the previous step was scrolled.
          // No scroll animation or completion callback is required for navigation to work.
          scroll.scrollTo("setup-top", anchor: .top)
          headingFocus = step
        }
      }

      if let error = app.error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.pip(size: 12)).foregroundStyle(p.error).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 32).padding(.bottom, 12)
      }
      footer(p)
    }
    .background(p.panel)
    .onAppear {
      let args = ProcessInfo.processInfo.arguments
      if args.contains("--qa-screen"), let i = args.firstIndex(of: "--qa-step"),
        args.indices.contains(i + 1), let value = Int(args[i + 1])
      {
        step = min(2, max(0, value))
      }
    }
  }

  private func footer(_ p: SwitchPalette) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      if step == 2 {
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: setupStatus.icon).padding(.top, 1).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(setupStatus.title).fontWeight(.medium)
            Text(setupStatus.detail).foregroundStyle(p.secondary)
          }.fixedSize(horizontal: false, vertical: true)
        }
        .font(.pip(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
      }
      HStack(spacing: 16) {
        if step > 0 {
          Button("Back") { changeStep(step - 1) }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut("[", modifiers: .command)
        }
        Button("Explore first", action: explore)
          .buttonStyle(.plain).font(.pip(size: 12)).foregroundStyle(p.secondary)
          .help(
            models.phase == "paused"
              ? "Leave setup. Your paused download is kept; resume it in Models."
              : (activeDownload
                ? "Leave setup. The download continues while the app stays open; manage it in Models."
                : "Open the workspace without downloading or signing in. You can resume setup later.")
          )
        Spacer(minLength: 10)
        if step == 2 {
          Button("Open workspace") { app.completeOnboarding() }
            .buttonStyle(PrimaryButtonStyle()).disabled(!app.installed)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(
              app.installed
                ? "Finish setup with the selected verified model."
                : "Download and verify a model, or choose Explore first.")
        } else {
          Button {
            changeStep(step + 1)
          } label: {
            HStack(spacing: 10) {
              Text("Continue")
              Image(systemName: "arrow.right").accessibilityHidden(true)
            }
          }
          .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
          .accessibilityHint("Next: \(stepNames[step + 1])")
        }
      }
    }
    .padding(.horizontal, 32).padding(.vertical, 18)
    .background(p.canvas.opacity(0.65))
  }

  private var setupStatus: (icon: String, title: String, detail: String) {
    switch models.phase {
    case "downloading":
      return (
        "arrow.down.circle", "Your model is downloading.",
        "Keep Pip Hybrid open. You can explore now and pause or cancel in Models."
      )
    case "verifying":
      return (
        "checkmark.shield", "Checking the downloaded file.",
        "It won't be ready until its integrity check passes. You can keep exploring."
      )
    case "paused":
      return (
        "pause.circle", "Download paused. The downloaded bytes are kept.",
        "Choose Resume on the model row, or continue later in Models."
      )
    default:
      if app.installed {
        return (
          "checkmark.circle", "\(app.selectedModel.name) is verified on this Mac.",
          "Open the workspace. The model loads when you send your first local message."
        )
      }
      if models.phase == "failed" {
        return (
          "exclamationmark.triangle", "The download needs attention.",
          "Review the error and use Retry on the model row, or choose Explore first."
        )
      }
      if !supportedStarter {
        return (
          "info.circle", "Local model setup isn't available for this Mac.",
          unsupportedHardwareReason
            ?? "These starter models exceed the detected memory budget. Explore first to review other options."
        )
      }
      return (
        "arrow.down.circle", "Download one model to finish local setup.",
        "Downloads need internet and disk space. Explore first if you'd rather do this later."
      )
    }
  }

  private func changeStep(_ target: Int) {
    guard (0..<stepNames.count).contains(target) else { return }
    step = target
  }

  private func heading(_ text: String, size: CGFloat) -> some View {
    Text(text)
      .font(.pip(size: size, weight: .semibold)).tracking(-0.8)
      .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocus, equals: step)
  }

  private func introduction(_ p: SwitchPalette) -> some View {
    VStack(spacing: 23) {
      PipView(size: 96, greeting: true).padding(.top, 6)
      VStack(spacing: 13) {
        heading("Big ideas. Close to home.", size: 32)
        Text(
          "Meet Pip, your little local companion. Give an open model a home on your Mac and make a private space for your work."
        )
        .font(.pip(size: 14)).foregroundStyle(p.secondary).lineSpacing(4)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 550)
      }
      HStack(spacing: 15) {
        diagramNode("text.bubble", title: "Your message", p)
        Image(systemName: "arrow.right").foregroundStyle(p.secondary).accessibilityHidden(true)
        VStack(spacing: 9) {
          PipView(size: 52, live: false)
          Text("Your Mac").font(.pip(size: 12, weight: .medium))
        }.frame(maxWidth: .infinity)
        Image(systemName: "arrow.right").foregroundStyle(p.secondary).accessibilityHidden(true)
        diagramNode("doc.text", title: "Your answer", p)
      }
      .padding(.vertical, 21).padding(.horizontal, 20)
      .background(p.quiet.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Local chat: your message is processed on this Mac to produce your answer.")
      HStack(alignment: .top, spacing: 22) {
        benefit(
          "desktopcomputer", title: "Local by default",
          text: "Local chats use the engine on this Mac.", p)
        benefit(
          "person.crop.circle.badge.checkmark", title: "No account required",
          text: "Start locally without a subscription or API key.", p)
        benefit(
          "arrow.down.circle", title: "One clear setup",
          text: "Check this Mac, then choose a model.", p)
      }
      Text(
        "Model downloads use internet. ChatGPT is optional in Preferences. You review what leaves your Mac before each ChatGPT answer."
      )
      .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
      .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func hardware(_ p: SwitchPalette) -> some View {
    VStack(spacing: 24) {
      Image(systemName: "desktopcomputer").font(.pip(size: 43, weight: .ultraLight))
        .padding(.top, 12).accessibilityHidden(true)
      VStack(spacing: 12) {
        heading("A good place to start.", size: 36)
        Text("We've checked this Mac locally. Here's the room your model will work with.")
          .font(.pip(size: 14)).foregroundStyle(p.secondary).multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 0) {
        hardwareRow("Chip", app.device.chip)
        Divider().overlay(p.border)
        hardwareRow(
          "Memory",
          "\(Int(app.device.physicalMemory / 1_073_741_824)) GiB \(app.device.unifiedMemory ? "unified" : "physical")"
        )
        Divider().overlay(p.border)
        hardwareRow("GPU", app.device.gpuName)
      }
      .padding(.horizontal, 23)
      .background(p.quiet.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
      VStack(alignment: .leading, spacing: 10) {
        Label(
          app.device.unifiedMemory
            ? "Shared memory, counted once" : "Conservative memory estimates",
          systemImage: "memorychip"
        ).font(.pip(size: 13, weight: .semibold))
        Text(
          app.device.unifiedMemory
            ? "Your CPU and GPU share memory. We leave space for macOS and the model's working context instead of counting GPU memory twice."
            : "Memory pools stay separate. Models without a supported fit estimate stay unavailable."
        )
        .font(.pip(size: 12)).foregroundStyle(p.secondary).lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
        if !supportedStarter {
          Label(
            unsupportedHardwareReason
              ?? "These starter models exceed the detected memory budget. You can explore without downloading.",
            systemImage: "info.circle"
          ).font(.pip(size: 12)).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("No folders scanned. No serial number collected.").font(.pip(size: 11))
          .foregroundStyle(p.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func chooseModel(_ p: SwitchPalette) -> some View {
    VStack(alignment: .leading, spacing: 21) {
      VStack(alignment: .leading, spacing: 11) {
        heading("Pick a model to bring home.", size: 34)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Quick start is the smallest download. You can add other models from Models later.")
          .font(.pip(size: 13)).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(starterModels) { descriptor in
        ModelRow(app: app, models: models, model: descriptor)
      }
      if let error = models.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.pip(size: 12))
          .foregroundStyle(p.error).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(
        "Files come from the model publisher at a pinned version. SHA-256 verification checks each download before use. Fit is estimated at 4K context; quality and speed vary."
      )
      .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func hardwareRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 20) {
      Text(title).foregroundStyle(SwitchPalette(scheme).secondary)
      Spacer(minLength: 15)
      Text(value).fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }.font(.pip(size: 13)).padding(.vertical, 18)
      .accessibilityElement(children: .combine)
  }

  private func benefit(_ icon: String, title: String, text: String, _ p: SwitchPalette) -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: icon).font(.pip(size: 18)).foregroundStyle(p.secondary)
        .accessibilityHidden(true)
      Text(title).font(.pip(size: 12, weight: .semibold))
      Text(text).font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
  }

  private func diagramNode(_ icon: String, title: String, _ p: SwitchPalette) -> some View {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.pip(size: 26, weight: .light))
        .frame(width: 64, height: 51).background(p.panel, in: RoundedRectangle(cornerRadius: 13))
      Text(title).font(.pip(size: 12, weight: .medium))
    }.frame(maxWidth: .infinity)
  }
}
