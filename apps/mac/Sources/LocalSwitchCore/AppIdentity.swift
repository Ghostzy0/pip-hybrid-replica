import Foundation

/// Each source edition owns separate data and credentials. Stores are never adopted implicitly.
public enum PipAppIdentity {
  #if BASELINE_EDITION
    private static let baseEdition = "baseline"
    public static let isBaseline = true
    private static let baseName = "Pip Hybrid Baseline"
    private static let baseBundleIdentifier = "app.pip.hybrid.baseline"
  #else
    private static let baseEdition = "pip"
    public static let isBaseline = false
    private static let baseName = "Pip Hybrid"
    private static let baseBundleIdentifier = "app.pip.hybrid.mac"
  #endif
  #if ENHANCED_EDITION
    public static let isEnhanced = true
    public static let edition = baseEdition + "-plus"
    public static let displayName = baseName + " Plus"
    public static let bundleIdentifier = baseBundleIdentifier + ".plus"
    public static let version = "0.2.0"
  #else
    public static let isEnhanced = false
    public static let edition = baseEdition
    public static let displayName = baseName
    public static let bundleIdentifier = baseBundleIdentifier
    public static let version = "0.1.0"
  #endif
  public static let historyService = bundleIdentifier + ".history"
  public static let chatGPTService = bundleIdentifier + ".chatgpt"
  public static let secretsService = bundleIdentifier + ".secrets"

  public static var preferences: UserDefaults {
    if ProcessInfo.processInfo.arguments.contains("--qa-output") {
      return UserDefaults(
        suiteName: bundleIdentifier + ".qa.\(ProcessInfo.processInfo.processIdentifier)")!
    }
    // Bundled acceptance apps get their own standard preference domain too.
    if let current = Bundle.main.bundleIdentifier,
      current == bundleIdentifier || current.hasPrefix("app.pip.hybrid.acceptance.")
    {
      return .standard
    }
    return UserDefaults(suiteName: bundleIdentifier)!
  }

  public static func dataRoot(applicationSupport: URL? = nil) -> URL {
    let base =
      applicationSupport
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent(displayName, isDirectory: true)
  }

  public static func modelRoot(applicationSupport: URL? = nil) -> URL {
    dataRoot(applicationSupport: applicationSupport).appendingPathComponent(
      "Models", isDirectory: true)
  }
}
