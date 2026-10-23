import Foundation
import Security
import XCTest

@testable import LocalSwitchCore

final class SecretStorePolicyTests: XCTestCase {
  private func interactionAllowed() throws -> Bool {
    var value: DarwinBoolean = false
    let status = SecKeychainGetUserInteractionAllowed(&value)
    guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    return value.boolValue
  }
  func testBackgroundLoginKeychainPolicyDisallowsUIAndRestoresPreviousSetting() throws {
    let original = try interactionAllowed()
    let store = KeychainSecretStore(service: "synthetic.policy.only")
    try store.withInteractionPolicy { XCTAssertFalse(try interactionAllowed()) }
    XCTAssertEqual(try interactionAllowed(), original)
  }
  func testThrownOperationRestoresPolicyAndNestedAutomaticStoreCannotPrompt() throws {
    enum Expected: Error { case failure }
    let original = try interactionAllowed()
    let interactive = KeychainSecretStore(service: "synthetic.policy.only", allowInteraction: true)
    let automatic = KeychainSecretStore(service: "synthetic.policy.only")
    XCTAssertThrowsError(
      try interactive.withInteractionPolicy {
        XCTAssertTrue(try interactionAllowed())
        try automatic.withInteractionPolicy { XCTAssertFalse(try interactionAllowed()) }
        XCTAssertTrue(try interactionAllowed())
        throw Expected.failure
      })
    XCTAssertEqual(try interactionAllowed(), original)
  }

  func testConcurrentInteractiveAndAutomaticScopesSerializeInBothOrders() throws {
    try assertConcurrentScopesSerialize(firstAllowsInteraction: true)
    try assertConcurrentScopesSerialize(firstAllowsInteraction: false)
  }

  /// Deliberately overlap two stores without reading, writing or deleting a Keychain item.
  /// The first body holds its policy until the second worker has attempted entry.
  private func assertConcurrentScopesSerialize(firstAllowsInteraction: Bool) throws {
    let original = try interactionAllowed()
    let first = KeychainSecretStore(
      service: "synthetic.policy.first", allowInteraction: firstAllowsInteraction)
    let second = KeychainSecretStore(
      service: "synthetic.policy.second", allowInteraction: !firstAllowsInteraction)
    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondAttempting = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    let releaseSecond = DispatchSemaphore(value: 0)
    let firstFinished = expectation(description: "First policy scope finished")
    let secondFinished = expectation(description: "Second policy scope finished")

    DispatchQueue.global().async {
      defer { firstFinished.fulfill() }
      do {
        try first.withInteractionPolicy {
          XCTAssertEqual(try self.interactionAllowed(), firstAllowsInteraction)
          firstEntered.signal()
          guard releaseFirst.wait(timeout: .now() + 5) == .success else {
            XCTFail("Timed out releasing the first policy scope")
            return
          }
          XCTAssertEqual(try self.interactionAllowed(), firstAllowsInteraction)
        }
      } catch { XCTFail("First policy scope failed: \(error)") }
    }

    guard firstEntered.wait(timeout: .now() + 2) == .success else {
      releaseFirst.signal()
      // Keep every expectation balanced and wait for cleanup before another policy test runs.
      secondFinished.fulfill()
      wait(for: [firstFinished, secondFinished], timeout: 6)
      XCTFail("First policy scope did not enter")
      return
    }
    DispatchQueue.global().async {
      defer { secondFinished.fulfill() }
      secondAttempting.signal()
      do {
        try second.withInteractionPolicy {
          XCTAssertEqual(try self.interactionAllowed(), !firstAllowsInteraction)
          secondEntered.signal()
          guard releaseSecond.wait(timeout: .now() + 5) == .success else {
            XCTFail("Timed out releasing the second policy scope")
            return
          }
          XCTAssertEqual(try self.interactionAllowed(), !firstAllowsInteraction)
        }
      } catch { XCTFail("Second policy scope failed: \(error)") }
    }

    XCTAssertEqual(secondAttempting.wait(timeout: .now() + 2), .success)
    let enteredWhileFirstWasHeld = secondEntered.wait(timeout: .now() + 0.1)
    XCTAssertEqual(enteredWhileFirstWasHeld, .timedOut, "Policy scopes overlapped")
    XCTAssertEqual(try interactionAllowed(), firstAllowsInteraction)
    releaseFirst.signal()
    if enteredWhileFirstWasHeld == .timedOut {
      XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
    }
    releaseSecond.signal()
    wait(for: [firstFinished, secondFinished], timeout: 6)
    XCTAssertEqual(try interactionAllowed(), original)
  }
}
