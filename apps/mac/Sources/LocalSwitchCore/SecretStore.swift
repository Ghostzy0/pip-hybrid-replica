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

/// The ad-hoc developer app targets the Mac login Keychain (non-synchronising, app ACL).
/// Data-protection Keychain requires a provisioned access group on macOS; do not imply that
/// its WhenUnlockedThisDeviceOnly guarantee applies to the login-Keychain development path.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
  private static let interactionLock = NSRecursiveLock()
  private let service: String
  private let allowInteraction: Bool
  private let useDataProtectionKeychain: Bool
  public init(
    service: String = PipAppIdentity.secretsService, allowInteraction: Bool = false,
    useDataProtectionKeychain: Bool = false
  ) {
    self.service = service
    self.allowInteraction = allowInteraction
    self.useDataProtectionKeychain = useDataProtectionKeychain
  }
  /// Keep the same service/keychain when a user explicitly requests an unlock.
  public func withUserInteraction(_ allowed: Bool) -> KeychainSecretStore {
    KeychainSecretStore(
      service: service, allowInteraction: allowed,
      useDataProtectionKeychain: useDataProtectionKeychain)
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
    var previous: DarwinBoolean = false
    let fetched = SecKeychainGetUserInteractionAllowed(&previous)
    guard fetched == errSecSuccess else { throw SecretStoreError(status: fetched) }
    let changed = SecKeychainSetUserInteractionAllowed(allowInteraction)
    guard changed == errSecSuccess else { throw SecretStoreError(status: changed) }
    defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
    return try body()
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
