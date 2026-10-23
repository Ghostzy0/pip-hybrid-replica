import LocalSwitchCore
import SwiftUI

struct ModelLibraryView: View {
  @ObservedObject var app: AppModel
  @ObservedObject var models: ModelStore
  var compact = false
  @State private var query = ""
  private var visibleModels: [ModelDescriptor] {
    ModelDescriptor.catalogue.filter {
      query.isEmpty
        || ($0.name + " " + $0.summary + " " + $0.filename).localizedCaseInsensitiveContains(query)
    }
    .sorted { $0.memoryGiB < $1.memoryGiB }
  }
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let p = SwitchPalette(scheme)
    ScrollView {
      VStack(alignment: .leading, spacing: 23) {
        if !compact {
          VStack(alignment: .leading, spacing: 9) {
            Text("A model of your own.")
              .font(.pip(size: 33, weight: .semibold)).tracking(-0.6)
            Text(
              "Start small, then make room for more. Each download is checked before it can run."
            )
            .font(.pip(size: 13)).foregroundStyle(p.secondary).fixedSize(
              horizontal: false, vertical: true)
          }
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-output"),
          ProcessInfo.processInfo.arguments.contains("--qa-download-preview")
        {
          VStack(alignment: .leading, spacing: 12) {
            Text("Appearance preview · synthetic download states").font(
              .pip(size: 12, weight: .semibold))
            Text("Downloading · 42%").font(.pip(size: 11))
            ModelDownloadProgress(value: 0.42)
            Text("Paused · 42%").font(.pip(size: 11))
            ModelDownloadProgress(value: 0.42)
            Button("Disabled action") {}.buttonStyle(QuietButtonStyle()).disabled(true)
          }.padding(16).background(p.quiet, in: RoundedRectangle(cornerRadius: 18))
        }
        HStack(alignment: .top, spacing: 26) {
          modelFact(
            "memorychip",
            title:
              "\(Int(app.device.physicalMemory / 1_073_741_824)) GiB \(app.device.unifiedMemory ? "unified memory" : "memory")",
            detail: "Read from this Mac")
          modelFact(
            "internaldrive", title: "Stored on your Mac", detail: "Internet is used for downloads")
          modelFact(
            "checkmark.seal", title: "Pinned and verified", detail: "SHA-256 integrity checks")
        }
        TextField("Find a model", text: $query)
          .textFieldStyle(.roundedBorder).frame(maxWidth: 330).accessibilityLabel("Find a model")
        if visibleModels.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("No models match “\(query)”.").font(.pip(size: 13))
            Button("Clear search") { query = "" }.buttonStyle(QuietButtonStyle())
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 15)
        }
        VStack(spacing: 12) {
          ForEach(visibleModels) { descriptor in
            ModelRow(app: app, models: models, model: descriptor)
          }
        }
        if !app.onboardingComplete && app.installed {
          Button("Finish setup", action: app.completeOnboarding).buttonStyle(PrimaryButtonStyle())
        }
        Text(
          "Memory fit is a conservative estimate at 4K context, one conversation at a time. It includes room for the runtime and macOS. A fit estimate is not a quality or speed guarantee."
        )
        .font(.pip(size: 11)).foregroundStyle(p.secondary).lineSpacing(3)
        if let error = models.error {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.pip(size: 12)).foregroundStyle(p.error).textSelection(.enabled)
        }
      }.padding(compact ? 0 : 37).frame(maxWidth: 850, alignment: .leading).frame(
        maxWidth: .infinity)
    }
  }
  private func modelFact(_ icon: String, title: String, detail: String) -> some View {
    let p = SwitchPalette(scheme)
    return VStack(alignment: .leading, spacing: 7) {
      Image(systemName: icon).font(.pip(size: 18)).foregroundStyle(p.secondary)
      Text(title).font(.pip(size: 12, weight: .semibold))
      Text(detail).font(.pip(size: 11)).foregroundStyle(p.secondary).fixedSize(
        horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ModelRow: View {
  @ObservedObject var app: AppModel
  @ObservedObject var models: ModelStore
  let model: ModelDescriptor
  @State private var details = false
  @State private var removeConfirmation = false
  @Environment(\.colorScheme) private var scheme
  private var publisherURL: URL {
    let path = model.downloadURL.pathComponents.filter { $0 != "/" }.prefix(2).joined(
      separator: "/")
    return URL(string: "https://huggingface.co/" + path) ?? model.licenseURL
  }
  private var active: Bool { models.activeModelID == model.id }
  private var installed: Bool { models.installedURL(for: model) != nil }
  private var downloading: Bool {
    active && ["downloading", "paused", "verifying"].contains(models.phase)
  }
  private var otherTransfer: Bool {
    !active && ["downloading", "paused", "verifying"].contains(models.phase)
  }
  private var selected: Bool { app.selectedModelID == model.id }
  private var fitWarning: String {
    if app.device.architecture != "arm64" { return "This local alpha needs Apple Silicon." }
    if !app.device.unifiedMemory || app.device.recommendedWorkingSet == 0 {
      return "A supported unified Metal memory budget was not detected."
    }
    return "This model exceeds the current memory budget."
  }
  var body: some View {
    let p = SwitchPalette(scheme)
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 15) {
        ZStack {
          RoundedRectangle(cornerRadius: 12).fill(p.panel)
          Image(systemName: model.memoryGiB < 4 ? "leaf" : "square.stack.3d.up")
            .font(.pip(size: 23, weight: .light)).foregroundStyle(p.ink)
        }.frame(width: 49, height: 49).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 8) {
            Text(model.name).font(.pip(size: 16, weight: .semibold)).textSelection(.enabled)
            if model.id == "qwen3-0.6b-q8_0" {
              Text("Quick start").font(.pip(size: 10, weight: .medium)).padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(p.accent, in: Capsule()).foregroundStyle(p.accentInk)
            }
          }
          Text(model.summary).font(.pip(size: 12)).foregroundStyle(p.secondary).fixedSize(
            horizontal: false, vertical: true)
          Text(
            "\(byteLabel(model.bytes)) download · about \(model.memoryGiB, specifier: "%.1f") GiB model budget"
          )
          .font(.pip(size: 11)).foregroundStyle(p.secondary)
          if !model.fits(app.device) {
            Label(fitWarning, systemImage: "exclamationmark.circle")
              .font(.pip(size: 11)).foregroundStyle(p.error)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if installed {
          VStack(alignment: .trailing, spacing: 8) {
            Button {
              app.selectedModelID = model.id
              app.load()
            } label: {
              Label(
                selected ? "Load model" : "Use model",
                systemImage: selected ? "play.fill" : "arrow.right")
            }.buttonStyle(QuietButtonStyle()).disabled(
              app.isBusy || ["downloading", "paused", "verifying"].contains(models.phase))
            Label("Verified on disk", systemImage: "checkmark.circle")
              .font(.pip(size: 10)).foregroundStyle(p.secondary)
          }
        } else if !downloading {
          Button {
            app.selectedModelID = model.id
            app.download()
          } label: {
            Label(
              active && models.phase == "failed" ? "Retry" : "Download", systemImage: "arrow.down")
          }.buttonStyle(PrimaryButtonStyle())
            .disabled(!model.fits(app.device) || app.isBusy || otherTransfer)
        }
      }
      if downloading {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            if models.phase == "verifying" {
              Text("Checking the downloaded file…")
            } else {
              Text(models.phase == "paused" ? "Download paused" : "Downloading to this Mac")
            }
            Spacer()
            Text("\(byteLabel(models.downloadedBytes)) / \(byteLabel(model.bytes))")
              .monospacedDigit()
          }.font(.pip(size: 11)).foregroundStyle(p.secondary)
          if models.phase == "verifying" {
            ProgressView().controlSize(.small)
          } else {
            ModelDownloadProgress(value: models.progress)
          }
          HStack(spacing: 10) {
            if models.phase == "downloading" {
              Button("Pause", action: models.pause).buttonStyle(QuietButtonStyle())
            } else if models.phase == "paused" {
              Button("Resume") {
                app.selectedModelID = model.id
                app.download()
              }.buttonStyle(QuietButtonStyle())
            }
            if models.phase != "verifying" {
              Button("Cancel download", action: models.cancel).buttonStyle(.plain).font(
                .system(size: 11)
              ).foregroundStyle(p.secondary)
            }
            Spacer()
            if models.phase == "paused" {
              Text("Resume when you're ready.").font(.pip(size: 11)).foregroundStyle(p.secondary)
            }
          }
        }.padding(.top, 2)
      }
      HStack {
        Button {
          details.toggle()
        } label: {
          Label(
            details ? "Hide details" : "Source & details",
            systemImage: details ? "chevron.up" : "chevron.down"
          )
          .font(.pip(size: 10))
        }.buttonStyle(.plain).foregroundStyle(p.secondary)
        Spacer()
        if installed {
          Button("Remove") { removeConfirmation = true }
            .buttonStyle(.plain).font(.pip(size: 10)).foregroundStyle(p.secondary).disabled(
              app.isBusy
            )
            .confirmationDialog(
              "Remove \(model.name)?", isPresented: $removeConfirmation, titleVisibility: .visible
            ) {
              Button("Remove model", role: .destructive) { app.removeModel(model) }
              Button("Cancel", role: .cancel) {}
            } message: {
              Text(
                "This deletes the downloaded model from Pip Hybrid. Your conversations remain on this Mac. You can download it again."
              )
            }
        }
      }
      if details {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 14) {
            Link("Publisher source", destination: publisherURL)
            Link("Apache 2.0 licence", destination: model.licenseURL)
          }.font(.pip(size: 11))
          Text(model.filename).font(.pip(size: 10, design: .monospaced)).textSelection(.enabled)
          Text("SHA-256: \(model.sha256)")
            .font(.pip(size: 10, design: .monospaced)).foregroundStyle(p.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 4)
      }
    }
    .padding(20).background(p.quiet.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14).strokeBorder(
        selected ? p.secondary.opacity(0.6) : p.border.opacity(0.6), lineWidth: 1))
  }
}

/// Shared by real downloading/paused rows and isolated appearance previews.
struct ModelDownloadProgress: View {
  let value: Double
  var body: some View {
    ProgressView(value: min(1, max(0, value)))
      .progressViewStyle(ModelDownloadProgressStyle())
      .accessibilityLabel("Download progress")
  }
}

private struct ModelDownloadProgressStyle: ProgressViewStyle {
  @Environment(\.colorScheme) private var scheme
  func makeBody(configuration: Configuration) -> some View {
    let palette = SwitchPalette(scheme)
    let fraction = min(1, max(0, configuration.fractionCompleted ?? 0))
    // Native macOS tint is muted in an inactive window. Keep the actual segment
    // readable there too, retaining ProgressView's value/accessibility semantics.
    return GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(palette.border)
        Capsule().fill(palette.ink).frame(width: geometry.size.width * fraction)
      }
    }.frame(height: 6)
  }
}
