import Foundation
import LocalAuthentication
import Security

/// Narrow protected-storage boundary. Production uses Keychain; tests inject memory-only storage.
public protocol SecretStore {
  func read(_ key: String) throws -> Data?
  func write(_ data: Data, for key: String) throws
  func remove(_ key: String) throws
}

public struct SecretStoreError: LocalizedError {
  public let status: OSStatus
  public var errorDescription: String? {
    switch status {
    case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
      return
        "Your Mac Keychain is locked or access was not allowed. Unlock it and try again; existing protected data is unchanged."
    case errSecMissingEntitlement:
      return
        "This build is not entitled to use the selected protected Keychain. Existing protected data is unchanged."
    default:
      return
        "Protected Keychain storage is unavailable (code \(status)). Existing protected data is unchanged."
    }
  }
  public init(status: OSStatus) { self.status = status }
}

enum SecretStoreInteractionPolicyError: LocalizedError {
  case readFailed(OSStatus)
  case setFailed(OSStatus)
  case restoreFailed(OSStatus, fallbackStatus: OSStatus?)
  case setAndRestoreFailed(setStatus: OSStatus, restoreStatus: OSStatus, fallbackStatus: OSStatus?)
  case operationAndRestoreFailed(operation: Error, status: OSStatus)
  case stateUnknown

  var errorDescription: String? {
    switch self {
    case .readFailed(let status): return "Could not read the Keychain interaction policy (code \(status))."
    case .setFailed(let status): return "Could not set the Keychain interaction policy (code \(status))."
    case .restoreFailed(let status, let fallbackStatus):
      let fallback = fallbackStatus.map { " The fail-closed reset also failed (code \($0))." } ?? " A fail-closed reset was applied."
      return "Could not restore the Keychain interaction policy (code \(status)).\(fallback)"
    case .setAndRestoreFailed(let setStatus, let restoreStatus, let fallbackStatus):
      let fallback = fallbackStatus.map { " The fail-closed reset also failed (code \($0))." } ?? " A fail-closed reset was applied."
      return "Could not set the Keychain interaction policy (code \(setStatus)) or restore its prior value (code \(restoreStatus)).\(fallback)"
    case .operationAndRestoreFailed(let operation, let status):
      return "The protected operation failed (\(operation.localizedDescription)) and its Keychain interaction policy could not be restored (code \(status))."
    case .stateUnknown:
      return "Keychain interaction state is unknown after an earlier restore failure. Restart the app before using protected storage."
    }
  }
}

protocol KeychainInteractionPolicyBackend {
  func get(_ allowed: inout DarwinBoolean) -> OSStatus
  func set(_ allowed: Bool) -> OSStatus
}

private struct SystemKeychainInteractionPolicyBackend: KeychainInteractionPolicyBackend {
  func get(_ allowed: inout DarwinBoolean) -> OSStatus {
    SecKeychainGetUserInteractionAllowed(&allowed)
  }
  func set(_ allowed: Bool) -> OSStatus { SecKeychainSetUserInteractionAllowed(allowed) }
}

/// The ad-hoc developer app targets the Mac login Keychain (non-synchronising, app ACL).
/// Data-protection Keychain requires a provisioned access group on macOS; do not imply that
/// its WhenUnlockedThisDeviceOnly guarantee applies to the login-Keychain development path.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
  private static let interactionLock = NSRecursiveLock()
  private static var interactionPolicyStateUnknown = false
  private let service: String
  private let allowInteraction: Bool
  private let useDataProtectionKeychain: Bool
  private let interactionPolicyBackend: any KeychainInteractionPolicyBackend
  public convenience init(
    service: String = PipAppIdentity.secretsService, allowInteraction: Bool = false,
    useDataProtectionKeychain: Bool = false
  ) {
    self.init(
      service: service, allowInteraction: allowInteraction,
      useDataProtectionKeychain: useDataProtectionKeychain,
      interactionPolicyBackend: SystemKeychainInteractionPolicyBackend())
  }
  init(
    service: String, allowInteraction: Bool, useDataProtectionKeychain: Bool,
    interactionPolicyBackend: any KeychainInteractionPolicyBackend
  ) {
    self.service = service
    self.allowInteraction = allowInteraction
    self.useDataProtectionKeychain = useDataProtectionKeychain
    self.interactionPolicyBackend = interactionPolicyBackend
  }
  /// Keep the same service/keychain when a user explicitly requests an unlock.
  public func withUserInteraction(_ allowed: Bool) -> KeychainSecretStore {
    KeychainSecretStore(
      service: service, allowInteraction: allowed,
      useDataProtectionKeychain: useDataProtectionKeychain,
      interactionPolicyBackend: interactionPolicyBackend)
  }
  private func query(_ key: String) -> [String: Any] {
    var value: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecAttrSynchronizable as String: false,
      kSecUseAuthenticationContext as String: authenticationContext(),
    ]
    if useDataProtectionKeychain { value[kSecUseDataProtectionKeychain as String] = true }
    return value
  }
  private func authenticationContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = !allowInteraction
    return context
  }
  // LAContext.interactionNotAllowed does not reliably suppress legacy login-Keychain
  // ACL prompts. Serialize our stores around the legacy process-wide UI policy too.
  // This does not grant access or unlock anything: protected operations fail closed.
  func withInteractionPolicy<T>(_ body: () throws -> T) throws -> T {
    guard !useDataProtectionKeychain else { return try body() }
    Self.interactionLock.lock()
    defer { Self.interactionLock.unlock() }
    guard !Self.interactionPolicyStateUnknown else {
      throw SecretStoreInteractionPolicyError.stateUnknown
    }
    var previous: DarwinBoolean = false
    let fetched = interactionPolicyBackend.get(&previous)
    guard fetched == errSecSuccess else {
      throw SecretStoreInteractionPolicyError.readFailed(fetched)
    }
    let changed = interactionPolicyBackend.set(allowInteraction)
    if changed != errSecSuccess {
      let restored = interactionPolicyBackend.set(previous.boolValue)
      if restored != errSecSuccess {
        let fallback = interactionPolicyBackend.set(false)
        if fallback != errSecSuccess { Self.interactionPolicyStateUnknown = true }
        throw SecretStoreInteractionPolicyError.setAndRestoreFailed(
          setStatus: changed, restoreStatus: restored,
          fallbackStatus: fallback == errSecSuccess ? nil : fallback)
      }
      throw SecretStoreInteractionPolicyError.setFailed(changed)
    }

    let result: Result<T, Error>
    do { result = .success(try body()) } catch { result = .failure(error) }
    let restored = interactionPolicyBackend.set(previous.boolValue)
    guard restored == errSecSuccess else {
      let fallback = interactionPolicyBackend.set(false)
      if fallback != errSecSuccess { Self.interactionPolicyStateUnknown = true }
      if case .failure(let operation) = result {
        throw SecretStoreInteractionPolicyError.operationAndRestoreFailed(
          operation: operation, status: restored)
      }
      throw SecretStoreInteractionPolicyError.restoreFailed(
        restored, fallbackStatus: fallback == errSecSuccess ? nil : fallback)
    }
    return try result.get()
  }

  static func resetInteractionPolicyStateForTesting() {
    interactionLock.lock()
    interactionPolicyStateUnknown = false
    interactionLock.unlock()
  }
  public func read(_ key: String) throws -> Data? {
    try withInteractionPolicy { try readProtected(key) }
  }
  private func readProtected(_ key: String) throws -> Data? {
    var request = query(key)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SecretStoreError(status: status == errSecSuccess ? errSecDecode : status)
    }
    return data
  }
  public func write(_ data: Data, for key: String) throws {
    try withInteractionPolicy { try writeProtected(data, for: key) }
  }
  private func writeProtected(_ data: Data, for key: String) throws {
    let request = query(key)
    let status = SecItemUpdate(
      request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var addition = request
      addition[kSecValueData as String] = data
      if useDataProtectionKeychain {
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      }
      let added = SecItemAdd(addition as CFDictionary, nil)
      guard added == errSecSuccess else { throw SecretStoreError(status: added) }
    } else if status != errSecSuccess {
      throw SecretStoreError(status: status)
    }
  }
  public func remove(_ key: String) throws {
    try withInteractionPolicy { try removeProtected(key) }
  }
  private func removeProtected(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretStoreError(status: status)
    }
  }
}
