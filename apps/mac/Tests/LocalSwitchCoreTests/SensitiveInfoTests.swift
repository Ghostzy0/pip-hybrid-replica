import XCTest

@testable import LocalSwitchCore

final class SensitiveInfoTests: XCTestCase {
  func testEmailAndInternationalPhone() {
    let text = "Contact avery@example.com or +44 7700 900123."
    let findings = SensitiveInfo.scan(text)
    XCTAssertEqual(findings.map(\.kind), ["Email address", "Phone number"])
    XCTAssertEqual(SensitiveInfo.redacted(text), "Contact [Email address] or [Phone number].")
  }
  func testUTF16OffsetsSurviveEmojiAndAccentedPrefix() {
    let text = "🦊 café: person+tag@example.co.uk — 私のメール"
    let match = SensitiveInfo.scan(text)
    XCTAssertEqual(match.count, 1)
    XCTAssertEqual((text as NSString).substring(with: match[0].range), "person+tag@example.co.uk")
    XCTAssertEqual(SensitiveInfo.redacted(text), "🦊 café: [Email address] — 私のメール")
  }
  func testPrivateKeyTakesPriorityOverEmbeddedEmailAndIncompleteKeyIsHidden() {
    let text = "-----BEGIN PRIVATE KEY-----\navery@example.com\n-----END PRIVATE KEY-----"
    XCTAssertEqual(SensitiveInfo.scan(text).map(\.kind), ["Private key"])
    XCTAssertEqual(SensitiveInfo.redacted(text), "[Private key]")
    XCTAssertEqual(
      SensitiveInfo.redacted("prefix -----BEGIN OPENSSH PRIVATE KEY-----\npartial"),
      "prefix [Private key]")
  }
  func testCommonCredentialFormsAndNoSubstringMatch() {
    let openAI = "sk-proj-" + String(repeating: "A", count: 30)
    let github = "ghp_" + String(repeating: "B", count: 36)
    let google = "AIza" + String(repeating: "C", count: 35)
    let text = "\(openAI) \(github) \(google)"
    XCTAssertEqual(SensitiveInfo.scan(text).map(\.kind), ["API key", "API key", "API key"])
    XCTAssertEqual(SensitiveInfo.scan("identifier" + openAI).count, 0)
    XCTAssertEqual(SensitiveInfo.scan("sk-short-placeholder").count, 0)
  }
  func testOrdinaryIDsDatesAndNumbersAreNotPhoneHints() {
    XCTAssertTrue(
      SensitiveInfo.scan("Version 2026-10-21; ticket 1234567890123; port 4317; 2.5 GB").isEmpty)
    XCTAssertTrue(SensitiveInfo.scan("@home and person@example").isEmpty)
    XCTAssertTrue(SensitiveInfo.scan("").isEmpty)
  }
  func testNorthAmericanPhoneAndRepeatedEmailRangesDoNotOverlap() {
    let text = "(202) 555-0123 or a@b.example / a@b.example"
    let findings = SensitiveInfo.scan(text)
    XCTAssertEqual(findings.map(\.kind), ["Phone number", "Email address", "Email address"])
    for pair in zip(findings, findings.dropFirst()) {
      XCTAssertEqual(NSIntersectionRange(pair.0.range, pair.1.range).length, 0)
    }
    XCTAssertEqual(
      SensitiveInfo.redacted(text), "[Phone number] or [Email address] / [Email address]")
  }
  func testNoHintDoesNotMeanSafeAndUnformattedNumberIsDeliberatelyNotClassified() {
    XCTAssertTrue(SensitiveInfo.scan("My name is Avery and the door code is 1111").isEmpty)
    XCTAssertTrue(SensitiveInfo.scan("07700900123").isEmpty)
  }
}
