import SwiftUI

enum PipMetrics {
  static let control: CGFloat = 34
  static let buttonInset: CGFloat = 14
  static let cardRadius: CGFloat = 18
  static let composerRadius: CGFloat = 24
  static let contentWidth: CGFloat = 680
  #if BASELINE_EDITION
    static let textScale: CGFloat = 1
  #else
    static let textScale: CGFloat = 1.1
  #endif
}

struct SwitchPalette {
  let dark: Bool
  init(_ scheme: ColorScheme) { dark = scheme == .dark }
  #if BASELINE_EDITION
    var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    var panel: Color { canvas }
    var surface: Color { Color(nsColor: .controlBackgroundColor) }
    var raised: Color { Color(nsColor: .textBackgroundColor) }
    var quiet: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.35) }
    var ink: Color { Color(nsColor: .labelColor) }
    var secondary: Color { Color(nsColor: .secondaryLabelColor) }
    var border: Color { Color(nsColor: .separatorColor) }
    var controlLine: Color { Color(nsColor: .tertiaryLabelColor) }
    var accent: Color { ink }
    var accentInk: Color { canvas }
    var error: Color { Color(nsColor: .systemRed) }
    var success: Color { Color(nsColor: .systemGreen) }
  #else
    var canvas: Color { Color(hex: dark ? 0x0F0F0E : 0xFFFFFF) }
    var panel: Color { canvas }
    var surface: Color { Color(hex: dark ? 0x171716 : 0xFAFAFA) }
    var raised: Color { Color(hex: dark ? 0x1E1E1D : 0xFFFFFF) }
    var quiet: Color { Color(hex: dark ? 0x212120 : 0xF3F3F3) }
    var ink: Color { Color(hex: dark ? 0xF1F1EE : 0x121211) }
    var secondary: Color { Color(hex: dark ? 0xA3A3A0 : 0x555555) }
    var border: Color { Color(hex: dark ? 0x2A2A29 : 0xEBEBEB) }
    var controlLine: Color { Color(hex: dark ? 0x696968 : 0x929292) }
    var accent: Color { ink }
    var accentInk: Color { canvas }
    var error: Color { Color(hex: dark ? 0xFF8B7E : 0xAE2A1F) }
    var success: Color { Color(hex: dark ? 0x5FD394 : 0x1D7A46) }
  #endif
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255, opacity: 1)
  }
}

#if BASELINE_EDITION
  /// Preserve native button semantics, focus, disabled feedback and system styling.
  struct QuietButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      Button(configuration).buttonStyle(.bordered)
    }
  }

  struct PrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      Button(configuration).buttonStyle(.borderedProminent)
    }
  }
#else
  struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
      let p = SwitchPalette(scheme)
      configuration.label
        .font(.pip(size: 13, weight: .medium))
        .padding(.horizontal, PipMetrics.buttonInset)
        .frame(minHeight: PipMetrics.control)
        .background(p.quiet, in: Capsule())
        .foregroundStyle(enabled ? p.ink : p.secondary)
        .scaleEffect(configuration.isPressed && enabled && !reduced ? 0.97 : 1)
        .animation(reduced ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
  }

  struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
      let p = SwitchPalette(scheme)
      configuration.label
        .font(.pip(size: 13, weight: .medium))
        .padding(.horizontal, PipMetrics.buttonInset)
        .frame(minHeight: PipMetrics.control)
        .foregroundStyle(enabled ? p.canvas : p.secondary)
        .background(enabled ? p.ink : p.quiet, in: Capsule())
        .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
        .animation(reduced ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
  }

#endif

struct StatusPill: View {
  let title: String
  var systemImage = "desktopcomputer"
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let p = SwitchPalette(scheme)
    Label(title, systemImage: systemImage)
      .font(.pip(size: 11, weight: .medium))
      .foregroundStyle(p.secondary)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(p.quiet, in: Capsule())
  }
}

func byteLabel(_ bytes: Int64) -> String {
  ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
