import CryptoKit
import Foundation
import Security

public enum ChatGPTError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}

public struct ChatGPTIdentity: Equatable, Sendable {
  public let subject: String
  public let email: String?
  public let name: String?
}

/// Validates the signed identity, never treats a decoded JWT or email as authentication.
public enum IDTokenValidator {
  public static let issuer = "https://auth.openai.com"
  public static func validate(
    _ token: String, jwks: Data, clientID: String, nonce: String?,
    expectedSubject: String? = nil, now: Date = Date()
  ) throws -> ChatGPTIdentity {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard token.utf8.count <= 32_768, parts.count == 3,
      let headerData = decodeBase64URL(String(parts[0])),
      let payloadData = decodeBase64URL(String(parts[1])),
      let signature = decodeBase64URL(String(parts[2])),
      let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
      header["alg"] as? String == "RS256", header["crit"] == nil,
      let kid = header["kid"] as? String, !kid.isEmpty, kid.utf8.count < 256,
      let document = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
      let keys = document["keys"] as? [[String: Any]], keys.count <= 30
    else { throw invalidIdentity() }
    let candidates = keys.filter { $0["kid"] as? String == kid }
    guard candidates.count == 1, let jwk = candidates.first,
      jwk["kty"] as? String == "RSA", jwk["use"] == nil || jwk["use"] as? String == "sig",
      jwk["alg"] == nil || jwk["alg"] as? String == "RS256",
      let n = jwk["n"] as? String, let modulus = decodeBase64URL(n),
      (256...1024).contains(modulus.count),
      let e = jwk["e"] as? String, let exponent = decodeBase64URL(e),
      (1...8).contains(exponent.count)
    else { throw invalidIdentity() }
    let der = sequence(integer(modulus) + integer(exponent))
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
    ]
    var keyError: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &keyError),
      SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256)
    else { throw invalidIdentity() }
    var signatureError: Unmanaged<CFError>?
    let message = Data((String(parts[0]) + "." + String(parts[1])).utf8)
    guard
      SecKeyVerifySignature(
        key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData,
        &signatureError),
      let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
      claims["iss"] as? String == issuer,
      let subject = claims["sub"] as? String, !subject.isEmpty, subject.utf8.count <= 256,
      let exp = claims["exp"] as? NSNumber, CFGetTypeID(exp) != CFBooleanGetTypeID(),
      exp.doubleValue > now.timeIntervalSince1970,
      let iat = claims["iat"] as? NSNumber, CFGetTypeID(iat) != CFBooleanGetTypeID(),
      iat.doubleValue <= now.timeIntervalSince1970 + 60
    else { throw invalidIdentity() }
    let audiences: [String]
    if let single = claims["aud"] as? String {
      audiences = [single]
    } else if let values = claims["aud"] as? [String] {
      audiences = values
    } else {
      throw invalidIdentity()
    }
    guard audiences.contains(clientID), !clientID.isEmpty,
      claims["azp"] == nil || claims["azp"] as? String == clientID,
      audiences.count <= 1 || claims["azp"] as? String == clientID
    else { throw invalidIdentity() }
    if let notBefore = claims["nbf"] as? NSNumber,
      notBefore.doubleValue > now.timeIntervalSince1970 + 30
    {
      throw invalidIdentity()
    }
    if let nonce {
      guard let actual = claims["nonce"] as? String, constantEqual(actual, nonce) else {
        throw invalidIdentity()
      }
    }
    if let expectedSubject {
      guard constantEqual(subject, expectedSubject) else {
        throw ChatGPTError.message(
          "This sign-in belongs to a different ChatGPT identity. The saved connection was not replaced."
        )
      }
    }
    let email =
      claims["email_verified"] as? Bool == true
      ? limited(claims["email"] as? String, maximum: 320) : nil
    return ChatGPTIdentity(
      subject: subject, email: email, name: limited(claims["name"] as? String, maximum: 150))
  }
  private static func limited(_ value: String?, maximum: Int) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= maximum else { return nil }
    return value
  }
  static func constantEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
  }
  public static func decodeBase64URL(_ value: String) -> Data? {
    guard value.range(of: "^[A-Za-z0-9_-]*$", options: .regularExpression) != nil,
      value.count % 4 != 1
    else { return nil }
    let padded =
      value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - value.count % 4) % 4)
    return Data(base64Encoded: padded)
  }
  static func encodeBase64URL(_ value: Data) -> String {
    value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
  private static func length(_ value: Int) -> Data {
    if value < 128 { return Data([UInt8(value)]) }
    var number = value
    var bytes = [UInt8]()
    while number > 0 {
      bytes.insert(UInt8(number & 255), at: 0)
      number >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
  }
  private static func integer(_ bytes: Data) -> Data {
    var value = Data(bytes.drop(while: { $0 == 0 }))
    if value.isEmpty { value = Data([0]) }
    if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
    return Data([0x02]) + length(value.count) + value
  }
  private static func sequence(_ data: Data) -> Data { Data([0x30]) + length(data.count) + data }
  private static func invalidIdentity() -> ChatGPTError {
    .message(
      "ChatGPT identity validation failed. The connection was not saved. Start a fresh sign-in.")
  }
}
