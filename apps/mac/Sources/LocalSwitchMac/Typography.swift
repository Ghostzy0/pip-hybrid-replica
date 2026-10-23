import AppKit
import CoreText
import SwiftUI

enum PipTypography {
  static func registerBundledFonts() {
    #if BASELINE_EDITION
      // The baseline uses system fonts and does not register bundled font files.
      return
    #else
      guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return }
      for name in ["Geist", "GeistMono"] {
        let url = folder.appendingPathComponent(name + ".ttf")
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    #endif
  }
}

extension Font {
  static func pip(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default)
    -> Font
  {
    #if BASELINE_EDITION
      return .system(size: size * PipMetrics.textScale, weight: weight, design: design)
    #else
      let family = design == .monospaced ? "GeistMono" : "Geist"
      let face: String
      switch weight {
      case .bold, .heavy, .black: face = "Bold"
      case .semibold: face = "SemiBold"
      case .medium: face = "Medium"
      default: face = "Regular"
      }
      return .custom(family + "-" + face, size: size * PipMetrics.textScale)
    #endif
  }
}
