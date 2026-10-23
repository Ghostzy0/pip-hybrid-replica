import Foundation

/// An advisory match, not a guarantee that every sensitive value was found.
/// Ranges use UTF-16 coordinates, compatible with NSString and native text selections.
public struct SensitiveFinding: Equatable, Sendable {
  public let kind: String
  public let range: NSRange
  public init(kind: String, range: NSRange) {
    self.kind = kind
    self.range = range
  }
}

/// Deterministic, on-device hints. Never logs or sends the inspected content.
/// General names, addresses, contextual secrets and many international formats are not covered.
public enum SensitiveInfo {
  // Priority matters: credentials/key blocks win over incidental email/phone matches inside them.
  private static let patterns: [(String, String)] = [
    (
      "Private key",
      #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----[\s\S]*?(?:-----END (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|\z)"#
    ),
    (
      "API key",
      #"(?<![A-Za-z0-9_])(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{35}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,})(?![A-Za-z0-9_-])"#
    ),
    (
      "Email address",
      #"(?<![\p{L}\p{N}._%+\-])[A-Za-z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,63}(?![\p{L}\p{N}_\-])"#
    ),
    // Require a plus prefix or a clearly formatted national number. Avoid treating every ID as a phone.
    (
      "Phone number",
      #"(?<![\p{L}\p{N}])(?:\+[1-9][0-9]{0,2}[ .\-]?(?:\([0-9]{1,4}\)|[0-9]{1,4})(?:[ .\-]?[0-9]{2,4}){2,4}|(?:\([0-9]{3}\)|[0-9]{3})[ .\-][0-9]{3}[ .\-][0-9]{4}|0[0-9]{3,4}[ .\-][0-9]{3}[ .\-][0-9]{3,4})(?![\p{L}\p{N}])"#
    ),
  ]
  private static let rules: [(String, NSRegularExpression)] = patterns.compactMap { kind, pattern in
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    return (kind, regex)
  }

  public static func scan(_ text: String) -> [SensitiveFinding] {
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    let string = text as NSString
    var findings: [SensitiveFinding] = []
    for (kind, regex) in rules {
      for match in regex.matches(in: text, range: full) {
        let range = match.range
        if kind == "Phone number" {
          let digits = string.substring(with: range).filter { $0.isNumber }.count
          guard (10...15).contains(digits) else { continue }
        }
        guard !findings.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else {
          continue
        }
        findings.append(SensitiveFinding(kind: kind, range: range))
      }
    }
    return findings.sorted { $0.range.location < $1.range.location }
  }

  public static func redacted(_ text: String) -> String {
    let output = NSMutableString(string: text)
    for finding in scan(text).reversed() {
      output.replaceCharacters(in: finding.range, with: "[\(finding.kind)]")
    }
    return output as String
  }
}
