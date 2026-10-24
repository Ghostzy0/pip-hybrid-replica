import Foundation
import Security
import XCTest

@testable import LocalSwitchCore

final class SecretStorePolicyTests: XCTestCase {
  override func setUp() {
    super.setUp()
    KeychainSecretStore.resetInteractionPolicyStateForTesting()
  }

  override func tearDown() {
    KeychainSecretStore.resetInteractionPolicyStateForTesting()
    super.tearDown()
  }

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

  func testInjectedRestoreFailureIsSurfacedAndResetsToFailClosedPolicy() throws {
    let backend = MemoryInteractionPolicy(initial: true, setStatuses: [errSecSuccess, errSecNotAvailable, errSecSuccess])
    let store = injectedStore(backend, allowInteraction: false)
    var bodyRan = false

    XCTAssertThrowsError(try store.withInteractionPolicy { bodyRan = true }) { error in
      guard case SecretStoreInteractionPolicyError.restoreFailed(let status, let fallback) = error
      else { return XCTFail("Unexpected error: \(error)") }
      XCTAssertEqual(status, errSecNotAvailable)
      XCTAssertNil(fallback)
    }
    XCTAssertTrue(bodyRan)
    XCTAssertFalse(backend.allowed)
    XCTAssertEqual(backend.setCalls, [false, true, false])
  }

  func testInjectedPolicyReadAndSetFailuresAreSurfaced() throws {
    let readBackend = MemoryInteractionPolicy(initial: true, getStatus: errSecNotAvailable)
    let readStore = injectedStore(readBackend, allowInteraction: false)
    XCTAssertThrowsError(try readStore.withInteractionPolicy {}) { error in
      guard case SecretStoreInteractionPolicyError.readFailed(let status) = error
      else { return XCTFail("Unexpected error: \(error)") }
      XCTAssertEqual(status, errSecNotAvailable)
    }
    XCTAssertTrue(readBackend.setCalls.isEmpty)

    let setBackend = MemoryInteractionPolicy(
      initial: true, setStatuses: [errSecNotAvailable, errSecSuccess])
    let setStore = injectedStore(setBackend, allowInteraction: false)
    XCTAssertThrowsError(try setStore.withInteractionPolicy {}) { error in
      guard case SecretStoreInteractionPolicyError.setFailed(let status) = error
      else { return XCTFail("Unexpected error: \(error)") }
      XCTAssertEqual(status, errSecNotAvailable)
    }
    XCTAssertTrue(setBackend.allowed)
    XCTAssertEqual(setBackend.setCalls, [false, true])
  }

  func testOperationAndRestoreFailuresRemainExplicitTogether() throws {
    enum Expected: Error { case operation }
    let backend = MemoryInteractionPolicy(initial: true, setStatuses: [errSecSuccess, errSecNotAvailable, errSecSuccess])
    let store = injectedStore(backend, allowInteraction: true)

    XCTAssertThrowsError(try store.withInteractionPolicy { throw Expected.operation }) { error in
      guard case SecretStoreInteractionPolicyError.operationAndRestoreFailed(let operation, let status) = error
      else { return XCTFail("Unexpected error: \(error)") }
      XCTAssertTrue(operation is Expected)
      XCTAssertEqual(status, errSecNotAvailable)
    }
    XCTAssertFalse(backend.allowed)
  }

  func testInjectedNestedPoliciesRestoreOuterValueAndFinalValue() throws {
    let backend = MemoryInteractionPolicy(initial: true)
    let interactive = injectedStore(backend, allowInteraction: true)
    let automatic = injectedStore(backend, allowInteraction: false)

    try interactive.withInteractionPolicy {
      XCTAssertTrue(backend.allowed)
      try automatic.withInteractionPolicy {
        XCTAssertFalse(backend.allowed)
      }
      XCTAssertTrue(backend.allowed)
    }
    XCTAssertTrue(backend.allowed)
    XCTAssertEqual(backend.setCalls, [true, false, true, true])
  }

  func testUnknownPolicyStateBlocksFurtherProtectedScopes() throws {
    let backend = MemoryInteractionPolicy(
      initial: true, setStatuses: [errSecSuccess, errSecNotAvailable, errSecNotAvailable])
    let store = injectedStore(backend, allowInteraction: false)
    XCTAssertThrowsError(try store.withInteractionPolicy {})
    let callsAfterFailure = backend.setCalls.count
    XCTAssertThrowsError(try store.withInteractionPolicy {}) { error in
      XCTAssertTrue(error is SecretStoreInteractionPolicyError)
      XCTAssertEqual(error.localizedDescription, SecretStoreInteractionPolicyError.stateUnknown.localizedDescription)
    }
    XCTAssertEqual(backend.setCalls.count, callsAfterFailure)
  }

  private func injectedStore(
    _ backend: MemoryInteractionPolicy, allowInteraction: Bool
  ) -> KeychainSecretStore {
    KeychainSecretStore(
      service: "synthetic.policy.injected", allowInteraction: allowInteraction,
      useDataProtectionKeychain: false, interactionPolicyBackend: backend)
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

private final class MemoryInteractionPolicy: KeychainInteractionPolicyBackend {
  var allowed: Bool
  let getStatus: OSStatus
  var setStatuses: [OSStatus]
  private(set) var setCalls: [Bool] = []

  init(initial: Bool, getStatus: OSStatus = errSecSuccess, setStatuses: [OSStatus] = []) {
    allowed = initial
    self.getStatus = getStatus
    self.setStatuses = setStatuses
  }

  func get(_ value: inout DarwinBoolean) -> OSStatus {
    value = DarwinBoolean(allowed)
    return getStatus
  }

  func set(_ value: Bool) -> OSStatus {
    setCalls.append(value)
    let status = setStatuses.isEmpty ? errSecSuccess : setStatuses.removeFirst()
    if status == errSecSuccess { allowed = value }
    return status
  }
}
