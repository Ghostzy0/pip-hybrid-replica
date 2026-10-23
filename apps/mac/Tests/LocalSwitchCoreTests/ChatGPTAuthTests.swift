import CryptoKit
import Foundation
import Security
import XCTest

@testable import LocalSwitchCore

private final class AuthMemorySecrets: SecretStore {
  var values = [String: Data]()
  var refusesWrite = false
  var refusesRead = false
  var dropsWrite = false
  func read(_ key: String) throws -> Data? {
    if refusesRead { throw ChatGPTError.message("Synthetic storage locked") }
    return values[key]
  }
  func write(_ data: Data, for key: String) throws {
    if refusesWrite { throw ChatGPTError.message("Synthetic storage failure") }
    if !dropsWrite { values[key] = data }
  }
  func remove(_ key: String) throws { values[key] = nil }
}

private func syntheticRequestBody(_ request: URLRequest) -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var bytes = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while stream.hasBytesAvailable && bytes.count <= 131_072 {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count <= 0 { break }
    bytes.append(contentsOf: buffer.prefix(count))
  }
  return bytes
}

private final class AuthFixtureProtocol: URLProtocol {
  static let lock = NSLock()
  static var handler: ((URLRequest) throws -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      Self.lock.lock()
      let handler = Self.handler
      Self.lock.unlock()
      guard let handler, let url = request.url else {
        throw ChatGPTError.message("Missing synthetic handler")
      }
      let (status, data) = try handler(request)
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": url.path == "/v1/responses" ? "text/event-stream" : "application/json"
        ])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

/// Releases the newer request first, so ordering is tested without blocking URLProtocol's queue.
private final class DelayedCatalogueProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var count = 0
  private static var failFirst = false
  static func reset(failOlder: Bool) {
    lock.lock()
    defer { lock.unlock() }
    count = 0
    failFirst = failOlder
  }
  static var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.count += 1
    let ordinal = Self.count
    let fail = ordinal == 1 && Self.failFirst
    Self.lock.unlock()
    let slug = ordinal == 1 ? "older" : "newer"
    let body =
      fail
      ? Data(#"{"error":{"code":"synthetic_stale_failure"}}"#.utf8)
      : Data(
        "{\"models\":[{\"slug\":\"\(slug)\",\"display_name\":\"\(slug)\",\"visibility\":\"list\"}]}"
          .utf8)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: fail ? 503 : 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    DispatchQueue.global().asyncAfter(deadline: .now() + (ordinal == 1 ? 0.1 : 0)) { [self] in
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

private struct SyntheticRSA {
  let privateKey: SecKey
  let jwks: Data
  let kid = "synthetic-key"
  init() throws {
    var error: Unmanaged<CFError>?
    guard
      let key = SecKeyCreateRandomKey(
        [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error),
      let publicKey = SecKeyCopyPublicKey(key),
      let bytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
    else { throw ChatGPTError.message("Synthetic RSA generation failed") }
    privateKey = key
    var cursor = 0
    func value(_ bytes: Data, cursor: inout Int, expected: UInt8) throws -> Data {
      guard cursor < bytes.count, bytes[cursor] == expected else {
        throw ChatGPTError.message("Synthetic DER mismatch")
      }
      cursor += 1
      let start = bytes[cursor]
      cursor += 1
      let length: Int
      if start < 128 {
        length = Int(start)
      } else {
        var count = 0
        for _ in 0..<Int(start & 0x7f) {
          count = count * 256 + Int(bytes[cursor])
          cursor += 1
        }
        length = count
      }
      let data = bytes.subdata(in: cursor..<(cursor + length))
      cursor += length
      return data
    }
    let sequence = try value(bytes, cursor: &cursor, expected: 0x30)
    cursor = 0
    let n = try value(sequence, cursor: &cursor, expected: 0x02).drop(while: { $0 == 0 })
    let e = try value(sequence, cursor: &cursor, expected: 0x02).drop(while: { $0 == 0 })
    jwks = try JSONSerialization.data(withJSONObject: [
      "keys": [
        [
          "kid": "synthetic-key", "kty": "RSA", "use": "sig", "alg": "RS256",
          "n": IDTokenValidator.encodeBase64URL(Data(n)),
          "e": IDTokenValidator.encodeBase64URL(Data(e)),
        ]
      ]
    ])
  }
  func token(
    client: String = "oaiapp_synthetic", nonce: String? = "nonce",
    subject: String = "synthetic-subject", now: Date = Date(), changes: [String: Any] = [:],
    headerChanges: [String: Any] = [:]
  ) throws -> String {
    var claims: [String: Any] = [
      "iss": IDTokenValidator.issuer, "aud": client, "sub": subject,
      "exp": now.addingTimeInterval(600).timeIntervalSince1970, "iat": now.timeIntervalSince1970,
      "email": "synthetic@example.com", "email_verified": true, "name": "Synthetic account",
    ]
    if let nonce { claims["nonce"] = nonce }
    for (key, value) in changes { claims[key] = value }
    var header: [String: Any] = ["alg": "RS256", "kid": kid]
    for (key, value) in headerChanges { header[key] = value }
    let signed =
      IDTokenValidator.encodeBase64URL(try JSONSerialization.data(withJSONObject: header)) + "."
      + IDTokenValidator.encodeBase64URL(try JSONSerialization.data(withJSONObject: claims))
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, &error)
        as Data?
    else { throw ChatGPTError.message("Synthetic signing failed") }
    return signed + "." + IDTokenValidator.encodeBase64URL(signature)
  }
}

@MainActor final class ChatGPTAuthTests: XCTestCase {
  override func tearDown() {
    AuthFixtureProtocol.lock.lock()
    AuthFixtureProtocol.handler = nil
    AuthFixtureProtocol.lock.unlock()
    super.tearDown()
  }
  func testSignedIdentityRejectsAlgorithmIssuerAudienceNonceExpiryAndTamper() throws {
    let rsa = try SyntheticRSA()
    let now = Date()
    let good = try rsa.token(now: now)
    XCTAssertEqual(
      try IDTokenValidator.validate(
        good, jwks: rsa.jwks, clientID: "oaiapp_synthetic", nonce: "nonce", now: now
      ).subject, "synthetic-subject")
    let variants: [[String: Any]] = [
      ["iss": "https://attacker.invalid"], ["aud": "wrong-client"], ["nonce": "wrong-nonce"],
      ["exp": now.addingTimeInterval(-1).timeIntervalSince1970],
      ["iat": now.addingTimeInterval(500).timeIntervalSince1970],
      ["aud": ["oaiapp_synthetic", "another-client"]],
    ]
    for changes in variants {
      XCTAssertThrowsError(
        try IDTokenValidator.validate(
          rsa.token(now: now, changes: changes), jwks: rsa.jwks, clientID: "oaiapp_synthetic",
          nonce: "nonce", now: now))
    }
    XCTAssertThrowsError(
      try IDTokenValidator.validate(
        rsa.token(nonce: nil), jwks: rsa.jwks, clientID: "oaiapp_synthetic", nonce: "nonce"))
    XCTAssertThrowsError(
      try IDTokenValidator.validate(
        rsa.token(headerChanges: ["alg": "none"]), jwks: rsa.jwks, clientID: "oaiapp_synthetic",
        nonce: "nonce"))
    XCTAssertThrowsError(
      try IDTokenValidator.validate(
        good, jwks: rsa.jwks, clientID: "oaiapp_synthetic", nonce: "nonce",
        expectedSubject: "other-identity"))
    let parts = good.split(separator: ".")
    let tampered =
      String(parts[0]) + "." + IDTokenValidator.encodeBase64URL(Data("{}".utf8)) + "."
      + String(parts[2])
    XCTAssertThrowsError(
      try IDTokenValidator.validate(
        tampered, jwks: rsa.jwks, clientID: "oaiapp_synthetic", nonce: "nonce"))
  }
  func testPKCEAndOwnDynamicRegistrationAndReturningClientMapping() throws {
    let first = try ChatGPTAuthorizationAttempt(
      redirectURI: URL(string: "http://127.0.0.1:32123/auth/callback")!,
      hostID: "urn:uuid:synthetic-host")
    let second = try ChatGPTAuthorizationAttempt(
      redirectURI: first.redirectURI, hostID: "urn:uuid:synthetic-host")
    let fields = Dictionary(
      uniqueKeysWithValues: URLComponents(
        url: first.authorizationURL(), resolvingAgainstBaseURL: false)!.queryItems!.map {
          ($0.name, $0.value!)
        })
    XCTAssertEqual(fields["client_id"], "dynamic_agent_client")
    XCTAssertEqual(fields["agent_name_hint"], PipAppIdentity.displayName)
    XCTAssertNotEqual(first.state, second.state)
    XCTAssertNotEqual(first.verifier, second.verifier)
    XCTAssertNotEqual(first.nonce, second.nonce)
    XCTAssertEqual(
      fields["code_challenge"],
      IDTokenValidator.encodeBase64URL(Data(SHA256.hash(data: Data(first.verifier.utf8)))))
    XCTAssertThrowsError(
      try first.issuedClientID(from: OAuthCallbackResult(code: "fake", clientID: nil, error: nil)))
    XCTAssertThrowsError(
      try first.issuedClientID(
        from: OAuthCallbackResult(code: "fake", clientID: "dynamic_agent_client", error: nil)))
    let returning = try ChatGPTAuthorizationAttempt(
      redirectURI: first.redirectURI, hostID: "urn:uuid:synthetic-host",
      issuedClientID: "oaiapp_synthetic")
    XCTAssertFalse(returning.authorizationURL().absoluteString.contains("agent_name_hint"))
    XCTAssertEqual(
      try returning.issuedClientID(
        from: OAuthCallbackResult(code: "fake", clientID: nil, error: nil)), "oaiapp_synthetic")
    XCTAssertThrowsError(
      try returning.issuedClientID(
        from: OAuthCallbackResult(code: "fake", clientID: "oaiapp_other", error: nil)))
    XCTAssertThrowsError(
      try ChatGPTAuthorizationAttempt(
        redirectURI: URL(string: "http://localhost:123/auth/callback")!, hostID: "host"))
  }
  func testCallbackRejectsDuplicateStateHostPathMethodAndBody() throws {
    func raw(
      _ target: String, host: String = "127.0.0.1:32123", method: String = "GET", extra: String = ""
    ) -> Data { Data("\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\n\(extra)\r\n".utf8) }
    XCTAssertEqual(
      try OAuthCallbackParser.parse(
        raw("/auth/callback?state=right&code=fake&client_id=oaiapp_synthetic"), port: 32123,
        expectedState: "right"
      ).code, "fake")
    for bytes in [
      raw("/auth/callback?state=wrong&code=fake"),
      raw("/auth/callback?state=right&state=right&code=fake"),
      raw("/callback?state=right&code=fake"),
      raw("/auth/callback?state=right&code=fake", host: "attacker.invalid"),
      raw("/auth/callback?state=right&code=fake", method: "POST"),
      raw("/auth/callback?state=right&code=fake", extra: "Content-Length: 10\r\n"),
      raw("/auth/callback?state=right&code=fake&error=access_denied"),
    ] {
      XCTAssertThrowsError(
        try OAuthCallbackParser.parse(bytes, port: 32123, expectedState: "right"))
    }
    XCTAssertEqual(
      try OAuthCallbackParser.parse(
        raw("/auth/callback?state=right&error=access_denied"), port: 32123, expectedState: "right"
      ).error, "access_denied")
  }
  func testResponseContractAndTerminalTruth() throws {
    let body = try ChatGPTResponseParser.requestBody(
      model: "eligible-model",
      messages: [
        RuntimeMessage(role: "system", content: "Be concise"),
        RuntimeMessage(role: "user", content: "Synthetic request"),
      ])
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["store"] as? Bool, false)
    XCTAssertEqual(json["stream"] as? Bool, true)
    XCTAssertEqual(json["instructions"] as? String, "Be concise")
    XCTAssertNil(json["max_output_tokens"])
    XCTAssertNil(json["previous_response_id"])
    XCTAssertNil(json["temperature"])
    XCTAssertEqual(
      try ChatGPTResponseParser.parse(
        Data(#"{"type":"response.output_text.delta","delta":"Hello 👋"}"#.utf8)), .delta("Hello 👋"))
    XCTAssertEqual(
      try ChatGPTResponseParser.parse(
        Data(#"{"type":"response.completed","response":{"status":"completed"}}"#.utf8)), .completed)
    for text in [
      #"{"type":"response.completed"}"#, #"{"type":"response.completed","response":{}}"#,
      #"{"type":"response.incomplete","response":{"status":"incomplete"}}"#,
      #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#,
    ] { XCTAssertThrowsError(try ChatGPTResponseParser.parse(Data(text.utf8))) }
    XCTAssertFalse(ChatGPTHTTPClient.allowed(URL(string: "http://api.openai.com/v1/responses")!))
    XCTAssertFalse(
      ChatGPTHTTPClient.allowed(URL(string: "https://api.openai.com.evil.invalid/v1/responses")!))
    XCTAssertFalse(
      ChatGPTHTTPClient.allowed(URL(string: "https://chatgpt.com/backend-api/models")!))
    XCTAssertEqual(
      String(data: ChatGPTHTTPClient.encodeForm(["code": "a+b&c=d"]), encoding: .utf8),
      "code=a%2Bb%26c%3Dd")
  }

  private func config() -> URLSessionConfiguration {
    let value = URLSessionConfiguration.ephemeral
    value.protocolClasses = [AuthFixtureProtocol.self]
    return value
  }
  private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Synthetic asynchronous operation timed out")
  }
  private func finish(_ url: URL, client: String = "oaiapp_synthetic", wrongState: Bool = false)
    async throws -> Int
  {
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) })
    var callback = URLComponents(string: values["redirect_uri"]!)!
    callback.queryItems = [
      URLQueryItem(name: "state", value: wrongState ? "wrong" : values["state"]!),
      URLQueryItem(name: "code", value: "synthetic-code"),
      URLQueryItem(name: "client_id", value: client),
    ]
    let c = URLSessionConfiguration.ephemeral
    c.connectionProxyDictionary = [:]
    let session = URLSession(configuration: c)
    defer { session.invalidateAndCancel() }
    let (_, response) = try await session.data(from: callback.url!)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
  }
  func testRealLoopbackStrayThenValidCallbackAndProtectedPlanConnection() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    var nonce = ""
    var responses = 0
    AuthFixtureProtocol.handler = { request in
      switch request.url!.path {
      case "/api/accounts/oauth/token":
        return (
          200,
          try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
            "id_token": rsa.token(nonce: nonce), "token_type": "Bearer", "expires_in": 3600,
            "scope":
              "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
          ])
        )
      case "/.well-known/jwks.json": return (200, rsa.jwks)
      case "/v1/models":
        return (
          200,
          Data(
            #"{"models":[{"slug":"eligible","display_name":"Eligible test model","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"}]}"#
              .utf8)
        )
      case "/v1/responses":
        responses += 1
        return (
          200,
          Data(
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Synthetic reply\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
              .utf8)
        )
      default: throw ChatGPTError.message("Unapproved synthetic endpoint")
      }
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    let url = try await connection.beginSignIn()
    nonce = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first(where: {
      $0.name == "nonce"
    })!.value!
    let rejected = try await finish(url, wrongState: true)
    XCTAssertEqual(rejected, 400)
    XCTAssertTrue(connection.isAuthorizing)
    let accepted = try await finish(url)
    XCTAssertEqual(accepted, 200)
    try await waitFor { !connection.isAuthorizing && !connection.models.isEmpty }
    XCTAssertTrue(connection.activeAccount?.planEnabled == true)
    XCTAssertEqual(connection.models.map(\.slug), ["eligible"])
    XCTAssertNotNil(secrets.values["registrations.v1"])
    var text = ""
    try await connection.generate(
      model: "eligible", messages: [RuntimeMessage(role: "user", content: "Synthetic")]
    ) { text += $0 }
    XCTAssertEqual(text, "Synthetic reply")
    XCTAssertEqual(responses, 1)
    connection.shutdown()
    let restored = ChatGPTConnection(secrets: secrets, configuration: config())
    XCTAssertEqual(restored.activeAccount?.subject, "synthetic-subject")
    XCTAssertTrue(restored.activeAccount?.planEnabled == true)
    restored.shutdown()
  }
  func testIdentityOnlyConsentCannotFetchModelsOrSend() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    var nonce = ""
    var privateRequests = 0
    AuthFixtureProtocol.handler = { request in
      if request.url!.path == "/.well-known/jwks.json" { return (200, rsa.jwks) }
      if request.url!.path == "/api/accounts/oauth/token" {
        return (
          200,
          try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-access", "id_token": rsa.token(nonce: nonce),
            "token_type": "Bearer", "expires_in": 3600, "scope": "openid profile email",
          ])
        )
      }
      privateRequests += 1
      throw ChatGPTError.message("Identity-only must not request models or content")
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    let url = try await connection.beginSignIn()
    nonce = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first(where: {
      $0.name == "nonce"
    })!.value!
    _ = try await finish(url)
    try await waitFor { !connection.isAuthorizing }
    XCTAssertTrue(connection.activeAccount?.isSignedIn == true)
    XCTAssertFalse(connection.activeAccount?.planEnabled == true)
    do {
      try await connection.generate(
        model: "anything", messages: [RuntimeMessage(role: "user", content: "Synthetic")]
      ) { _ in }
      XCTFail("Identity-only sent content")
    } catch {}
    XCTAssertEqual(privateRequests, 0)
    connection.shutdown()
  }
  private func seed(
    _ secrets: AuthMemorySecrets, now: Date, clients: [String] = ["oaiapp_synthetic"],
    earliest: Date? = nil, expiresIn: TimeInterval = 3600,
    retainedID: String = "synthetic-previous-identity"
  ) throws {
    let records = try clients.map { client -> [String: Any] in
      let account = ChatGPTAccount(
        id: client, clientID: client, subject: "synthetic-subject", email: nil,
        displayName: "Synthetic", planEnabled: true, isSignedIn: true,
        expiresAt: now.addingTimeInterval(3600))
      let token = ChatGPTTokenSet(
        accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
        idToken: retainedID,
        scopes: ["openid", "offline_access", "chatgpt.tokens.use.direct"],
        expiresAt: now.addingTimeInterval(expiresIn), earliestRefreshAt: earliest)
      return [
        "account": try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)),
        "tokens": try JSONSerialization.jsonObject(with: JSONEncoder().encode(token)),
      ]
    }
    secrets.values["registrations.v1"] = try JSONSerialization.data(withJSONObject: [
      "version": 1, "activeID": clients[0], "registrations": records,
    ])
  }
  func testProtectedStorageExplicitReloadPreservesDataAndDoesNotWrite() throws {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    let original = secrets.values
    secrets.refusesRead = true
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    XCTAssertFalse(connection.protectedStorageAvailable)
    XCTAssertThrowsError(try connection.reloadProtectedStorage())
    XCTAssertEqual(secrets.values, original)
    secrets.refusesRead = false
    try connection.reloadProtectedStorage()
    XCTAssertTrue(connection.protectedStorageAvailable)
    XCTAssertEqual(connection.accounts.count, 1)
    XCTAssertEqual(secrets.values, original)
    secrets.values["registrations.v1"] = Data("invalid".utf8)
    XCTAssertThrowsError(try connection.reloadProtectedStorage())
    XCTAssertEqual(connection.accounts.count, 1)
    connection.shutdown()
  }
  func testRefreshScopeDowngradeRotatesProtectedCredentialsWithoutSendingPrompt() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    var time = Date()
    try seed(secrets, now: time)
    var refreshes = 0
    var responses = 0
    AuthFixtureProtocol.handler = { request in
      switch request.url!.path {
      case "/v1/models":
        return (
          200,
          Data(
            #"{"models":[{"slug":"eligible","display_name":"Eligible","visibility":"list"}]}"#.utf8)
        )
      case "/api/accounts/oauth/token":
        refreshes += 1
        return (
          200,
          try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-renewed", "refresh_token": "synthetic-replacement",
            "token_type": "Bearer", "expires_in": 3600, "scope": "openid offline_access",
            "id_token": rsa.token(nonce: nil, now: time),
          ])
        )
      case "/.well-known/jwks.json": return (200, rsa.jwks)
      case "/v1/responses":
        responses += 1
        throw ChatGPTError.message("Downgraded scope must not dispatch")
      default: throw ChatGPTError.message("Unexpected synthetic endpoint")
      }
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config(), now: { time })
    await connection.refreshModels()
    XCTAssertEqual(connection.models.count, 1)
    time = time.addingTimeInterval(3600)
    do {
      try await connection.generate(
        model: "eligible",
        messages: [RuntimeMessage(role: "user", content: "Synthetic private text")]
      ) { _ in }
      XCTFail("Downgraded plan sent content")
    } catch {}
    XCTAssertEqual(refreshes, 1)
    XCTAssertEqual(responses, 0)
    XCTAssertFalse(connection.activeAccount?.planEnabled == true)
    XCTAssertTrue(connection.models.isEmpty)
    XCTAssertTrue(
      String(data: secrets.values["registrations.v1"]!, encoding: .utf8)!.contains(
        "synthetic-replacement"))
    connection.shutdown()
  }
  func testSignOutImmediatelyBlocksUseAndPreservesLaterAccountSelection() async throws {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date(), clients: ["oaiapp_synthetic", "oaiapp_second"])
    var responses = 0
    AuthFixtureProtocol.handler = { request in
      switch request.url!.path {
      case "/.well-known/openid-configuration":
        Thread.sleep(forTimeInterval: 0.08)
        return (
          200,
          Data(
            #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#
              .utf8)
        )
      case "/api/accounts/oauth/revoke": return (200, Data())
      case "/v1/models":
        return (
          200,
          Data(
            #"{"models":[{"slug":"eligible","display_name":"Eligible","visibility":"list"}]}"#.utf8)
        )
      case "/v1/responses":
        responses += 1
        throw ChatGPTError.message("Sign-out must block new content")
      default: throw ChatGPTError.message("Unexpected synthetic endpoint")
      }
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.refreshModels()
    let signingOut = Task { await connection.disconnect() }
    try await waitFor { connection.activeAccount?.isSignedIn == false }
    do {
      try await connection.generate(
        model: "eligible", messages: [RuntimeMessage(role: "user", content: "Synthetic")]
      ) { _ in }
      XCTFail("Sign-out permitted content")
    } catch {}
    await connection.selectAccount("oaiapp_second")
    await signingOut.value
    XCTAssertEqual(responses, 0)
    XCTAssertEqual(connection.activeAccountID, "oaiapp_second")
    XCTAssertNil(connection.lastRemoteRevocationConfirmed)  // B has no revocation receipt.
    let reloaded = ChatGPTConnection(secrets: secrets, configuration: config())
    XCTAssertEqual(reloaded.activeAccountID, "oaiapp_second")
    XCTAssertFalse(reloaded.accounts.first(where: { $0.id == "oaiapp_synthetic" })!.isSignedIn)
    reloaded.shutdown()
    connection.shutdown()
  }
  func testExplicitAccountSelectionCancelsPendingAuthorization() async throws {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    AuthFixtureProtocol.handler = { _ in (200, Data(#"{"models":[]}"#.utf8)) }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    _ = try await connection.beginSignIn()
    XCTAssertTrue(connection.isAuthorizing)
    await connection.selectAccount("oaiapp_synthetic")
    XCTAssertFalse(connection.isAuthorizing)
    XCTAssertEqual(connection.activeAccountID, "oaiapp_synthetic")
    connection.shutdown()
  }
  func testSSEByteFramingHandlesUnicodeCRLFAndRequiresRealCompletion() throws {
    let text =
      "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 🌱\"}\r\n\r\ndata: [DONE]\r\n\r\n"
    var framer = ChatGPTSSEFramer()
    var output = ""
    var completed = false
    for byte in text.utf8 {
      if let event = try framer.append(byte) {
        let parsed = try ChatGPTResponseParser.parse(event)
        switch parsed {
        case .delta(let delta): output += delta
        case .completed: completed = true
        case .other: break
        }
      }
    }
    XCTAssertEqual(output, "Hello 🌱")
    XCTAssertTrue(framer.sawDone)
    XCTAssertFalse(completed)
  }

  func testLockedReloadAfterConnectedSessionBlocksAllProviderUse() async throws {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    var requests = 0
    AuthFixtureProtocol.handler = { request in
      requests += 1
      return (
        200,
        Data(
          #"{"models":[{"slug":"eligible","display_name":"Eligible","visibility":"list"}]}"#.utf8)
      )
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.refreshModels()
    XCTAssertEqual(connection.models.count, 1)
    secrets.refusesRead = true
    XCTAssertThrowsError(try connection.reloadProtectedStorage())
    XCTAssertFalse(connection.protectedStorageAvailable)
    XCTAssertTrue(connection.models.isEmpty)
    await connection.refreshModels()
    do {
      try await connection.generate(
        model: "eligible", messages: [RuntimeMessage(role: "user", content: "Synthetic")]
      ) { _ in }
      XCTFail("Locked protected storage permitted content")
    } catch {}
    XCTAssertEqual(requests, 1)
    connection.shutdown()
  }
  func testConcurrentModelRefreshSerializesRotatingTokenRenewal() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    let start = Date()
    try seed(secrets, now: start)
    let advanced = start.addingTimeInterval(3600)
    var refreshes = 0
    AuthFixtureProtocol.handler = { request in
      switch request.url!.path {
      case "/api/accounts/oauth/token":
        refreshes += 1
        Thread.sleep(forTimeInterval: 0.05)
        return (
          200,
          try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-renewed", "refresh_token": "synthetic-rotated",
            "token_type": "Bearer", "expires_in": 3600,
            "scope": "openid offline_access chatgpt.tokens.use.direct",
            "id_token": rsa.token(nonce: nil, now: advanced),
          ])
        )
      case "/.well-known/jwks.json": return (200, rsa.jwks)
      case "/v1/models": return (200, Data(#"{"models":[]}"#.utf8))
      default: throw ChatGPTError.message("Unexpected endpoint")
      }
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config(), now: { advanced })
    async let first: Void = connection.refreshModels()
    async let second: Void = connection.refreshModels()
    _ = await (first, second)
    XCTAssertEqual(refreshes, 1)
    XCTAssertTrue(connection.activeAccount?.planEnabled == true)
    XCTAssertTrue(
      String(data: secrets.values["registrations.v1"]!, encoding: .utf8)!.contains(
        "synthetic-rotated"))
    connection.shutdown()
  }

  func testModelResponseCannotRestoreEligibilityAfterLockedReload() async throws {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    var started = false
    AuthFixtureProtocol.handler = { _ in
      started = true
      Thread.sleep(forTimeInterval: 0.08)
      return (
        200,
        Data(
          #"{"models":[{"slug":"eligible","display_name":"Eligible","visibility":"list"}]}"#.utf8)
      )
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    let loading = Task { await connection.refreshModels() }
    try await waitFor { started }
    secrets.refusesRead = true
    XCTAssertThrowsError(try connection.reloadProtectedStorage())
    await loading.value
    XCTAssertTrue(connection.models.isEmpty)
    XCTAssertFalse(connection.protectedStorageAvailable)
    XCTAssertEqual(connection.status, "Protected storage unavailable")
    connection.shutdown()
  }

  private func renewalResponse(_ rsa: SyntheticRSA, idToken: String? = nil, earliest: Date? = nil)
    throws -> Data
  {
    var object: [String: Any] = [
      "access_token": "synthetic-renewed", "refresh_token": "synthetic-rotated",
      "token_type": "Bearer", "expires_in": 3600,
      "scope": "openid offline_access chatgpt.tokens.use.direct",
    ]
    if let idToken { object["id_token"] = idToken }
    if let earliest { object["earliest_refresh_at"] = earliest.timeIntervalSince1970 }
    return try JSONSerialization.data(withJSONObject: object)
  }
  func testExplicitRenewalRespectsProviderEarliestTimeWithoutSending() async throws {
    let secrets = AuthMemorySecrets()
    let earliest = Date().addingTimeInterval(900)
    try seed(secrets, now: Date(), earliest: earliest)
    let original = secrets.values
    var requests = 0
    AuthFixtureProtocol.handler = { _ in
      requests += 1
      return (500, Data())
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    XCTAssertEqual(connection.nextSessionRenewalAt, earliest)
    XCTAssertFalse(connection.canRenewSession)
    await connection.renewSession()
    XCTAssertEqual(requests, 0)
    XCTAssertEqual(secrets.values, original)
    XCTAssertEqual(connection.sessionRenewalCount, 0)
    XCTAssertFalse(connection.isRenewingSession)
    connection.shutdown()
  }
  func testExplicitAndAutomaticRenewalShareOneValidatedPersistedRotation() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    let time = Date()
    try seed(secrets, now: time, expiresIn: 10)
    var refreshes = 0
    AuthFixtureProtocol.handler = { request in
      if request.url!.path == "/api/accounts/oauth/token" {
        refreshes += 1
        Thread.sleep(forTimeInterval: 0.08)
        return (
          200,
          try self.renewalResponse(
            rsa, idToken: rsa.token(nonce: nil), earliest: time.addingTimeInterval(1200))
        )
      }
      if request.url!.path == "/.well-known/jwks.json" { return (200, rsa.jwks) }
      return (200, Data(#"{"models":[]}"#.utf8))
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    let manual = Task { await connection.renewSession() }
    try await waitFor { connection.isRenewingSession }
    async let automatic: Void = connection.refreshModels()
    await connection.renewSession()  // duplicate click must not rotate again
    await manual.value
    await automatic
    XCTAssertEqual(refreshes, 1)
    XCTAssertEqual(connection.sessionRenewalCount, 1)
    XCTAssertEqual(connection.lastRenewalVerifiedFreshIdentity, true)
    XCTAssertNotNil(connection.lastSessionRenewalAt)
    XCTAssertEqual(
      try XCTUnwrap(connection.nextSessionRenewalAt).timeIntervalSince1970,
      time.addingTimeInterval(1200).timeIntervalSince1970, accuracy: 0.001)
    XCTAssertFalse(connection.canRenewSession)
    let restored = ChatGPTConnection(secrets: secrets, configuration: config())
    XCTAssertTrue(restored.activeAccount?.isSignedIn == true)
    XCTAssertNil(restored.lastSessionRenewalAt)
    XCTAssertEqual(restored.sessionRenewalCount, 0)
    restored.shutdown()
    connection.shutdown()
  }
  func testTemporaryRenewalFailurePreservesProtectedSessionAndDoesNotCountSuccess() async throws {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    let original = secrets.values
    AuthFixtureProtocol.handler = { _ in
      (503, Data(#"{"error":{"code":"temporarily_unavailable"}}"#.utf8))
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.renewSession()
    XCTAssertEqual(secrets.values, original)
    XCTAssertTrue(connection.activeAccount?.isSignedIn == true)
    XCTAssertTrue(connection.protectedStorageAvailable)
    XCTAssertEqual(connection.sessionRenewalCount, 0)
    XCTAssertNil(connection.lastSessionRenewalAt)
    connection.shutdown()
  }
  func testUnusableRenewalWithFailedProtectedWriteQuarantinesUntilSafeReload() async throws {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    var authenticated = 0
    AuthFixtureProtocol.handler = { request in
      authenticated += 1
      if request.url!.path == "/v1/models" {
        return (
          200,
          Data(
            #"{"models":[{"slug":"eligible","display_name":"Eligible","visibility":"list"}]}"#.utf8)
        )
      }
      return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.refreshModels()
    secrets.refusesWrite = true
    await connection.renewSession()
    XCTAssertFalse(connection.activeAccount?.isSignedIn == true)
    XCTAssertFalse(connection.protectedStorageAvailable)
    XCTAssertTrue(connection.models.isEmpty)
    XCTAssertThrowsError(try connection.reloadProtectedStorage())
    await connection.refreshModels()
    do {
      try await connection.generate(
        model: "eligible", messages: [RuntimeMessage(role: "user", content: "Synthetic")]
      ) { _ in }
      XCTFail("Unusable session dispatched")
    } catch {}
    XCTAssertEqual(authenticated, 2)
    secrets.refusesWrite = false
    try connection.reloadProtectedStorage()
    XCTAssertTrue(connection.protectedStorageAvailable)
    XCTAssertFalse(connection.activeAccount?.isSignedIn == true)
    let restored = ChatGPTConnection(secrets: secrets, configuration: config())
    XCTAssertFalse(restored.activeAccount?.isSignedIn == true)
    restored.shutdown()
    connection.shutdown()
  }
  func testSuccessfulRotationWithoutReadbackConfirmationFailsClosed() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    AuthFixtureProtocol.handler = { request in
      if request.url!.path == "/.well-known/jwks.json" { return (200, rsa.jwks) }
      return (200, try self.renewalResponse(rsa, idToken: rsa.token(nonce: nil)))
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    secrets.dropsWrite = true
    await connection.renewSession()
    XCTAssertFalse(connection.protectedStorageAvailable)
    XCTAssertFalse(connection.activeAccount?.isSignedIn == true)
    XCTAssertEqual(connection.sessionRenewalCount, 0)
    XCTAssertNil(connection.lastSessionRenewalAt)
    secrets.dropsWrite = false
    try connection.reloadProtectedStorage()
    XCTAssertFalse(connection.activeAccount?.isSignedIn == true)
    connection.shutdown()
  }
  func testOmittedRenewalIdentityRetainsVerifiedHintButExpiredSuppliedIdentityFails() async throws {
    let rsa = try SyntheticRSA()
    let expired = try rsa.token(nonce: nil, now: Date().addingTimeInterval(-7200))
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date(), retainedID: expired)
    var supplyExpired = false
    AuthFixtureProtocol.handler = { request in
      if request.url!.path == "/.well-known/jwks.json" { return (200, rsa.jwks) }
      return (200, try self.renewalResponse(rsa, idToken: supplyExpired ? expired : nil))
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.renewSession()
    XCTAssertEqual(connection.sessionRenewalCount, 1)
    XCTAssertEqual(connection.lastRenewalVerifiedFreshIdentity, false)
    XCTAssertTrue(connection.activeAccount?.isSignedIn == true)
    supplyExpired = true
    await connection.renewSession()
    XCTAssertFalse(connection.activeAccount?.isSignedIn == true)
    XCTAssertEqual(connection.sessionRenewalCount, 1)
    connection.shutdown()
  }
  func testSignOutWaitsForRotationAndRevokesLatestTokenWithoutRestoringSession() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    var refreshStarted = false
    var revokedLatest = false
    AuthFixtureProtocol.handler = { request in
      switch request.url!.path {
      case "/api/accounts/oauth/token":
        refreshStarted = true
        Thread.sleep(forTimeInterval: 0.08)
        return (200, try self.renewalResponse(rsa, idToken: rsa.token(nonce: nil)))
      case "/.well-known/jwks.json": return (200, rsa.jwks)
      case "/.well-known/openid-configuration":
        return (
          200,
          Data(
            #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#
              .utf8)
        )
      case "/api/accounts/oauth/revoke":
        revokedLatest = String(decoding: syntheticRequestBody(request), as: UTF8.self).contains(
          "token=synthetic-rotated")
        return (200, Data())
      default: throw ChatGPTError.message("Unexpected synthetic endpoint")
      }
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    let renewal = Task { await connection.renewSession() }
    try await waitFor { refreshStarted }
    await connection.disconnect()
    await renewal.value
    XCTAssertTrue(revokedLatest)
    XCTAssertFalse(connection.activeAccount?.isSignedIn == true)
    XCTAssertEqual(connection.sessionRenewalCount, 0)
    XCTAssertEqual(connection.lastRemoteRevocationConfirmed, true)
    XCTAssertEqual(connection.lastRemoteRevocationStatus, 200)
    XCTAssertEqual(connection.status, "Signed out of ChatGPT")
    XCTAssertNil(connection.error)
    connection.shutdown()
  }
  func testUnexpectedRevocationBodyNeverConfirmsAndRepeatedSignOutDoesNotInventSuccess()
    async throws
  {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    var revocations = 0
    AuthFixtureProtocol.handler = { request in
      if request.url!.path == "/.well-known/openid-configuration" {
        return (
          200,
          Data(
            #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#
              .utf8)
        )
      }
      revocations += 1
      return (200, Data(#"{"error":"synthetic_error"}"#.utf8))
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.disconnect()
    XCTAssertEqual(connection.lastRemoteRevocationConfirmed, false)
    XCTAssertEqual(connection.lastRemoteRevocationStatus, 200)
    await connection.disconnect()
    XCTAssertEqual(revocations, 1)
    XCTAssertEqual(connection.lastRemoteRevocationConfirmed, false)
    connection.shutdown()
  }
  func testRevocationRetriesTransientFailureAndConfirmsOnlyEmptySuccess() async throws {
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    var revocations = 0
    AuthFixtureProtocol.handler = { request in
      if request.url!.path == "/.well-known/openid-configuration" {
        return (
          200,
          Data(
            #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#
              .utf8)
        )
      }
      revocations += 1
      return revocations == 1 ? (503, Data()) : (200, Data())
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.disconnect()
    XCTAssertEqual(revocations, 2)
    XCTAssertEqual(connection.lastRemoteRevocationConfirmed, true)
    XCTAssertEqual(connection.lastRemoteRevocationStatus, 200)
    connection.shutdown()
  }

  func testNewAuthorizationNeverRevokesFailedPreviousRotationsToken() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date())
    var nonce = ""
    var revokedCurrent = false
    AuthFixtureProtocol.handler = { request in
      switch request.url!.path {
      case "/api/accounts/oauth/token":
        let form = String(decoding: syntheticRequestBody(request), as: UTF8.self)
        if form.contains("grant_type=refresh_token") {
          return (200, try self.renewalResponse(rsa, idToken: "invalid-synthetic-identity"))
        }
        return (
          200,
          try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-new-access", "refresh_token": "synthetic-new-session",
            "token_type": "Bearer", "expires_in": 3600,
            "scope": "openid offline_access chatgpt.tokens.use.direct",
            "id_token": rsa.token(nonce: nonce),
          ])
        )
      case "/.well-known/jwks.json": return (200, rsa.jwks)
      case "/v1/models": return (200, Data(#"{"models":[]}"#.utf8))
      case "/.well-known/openid-configuration":
        return (
          200,
          Data(
            #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#
              .utf8)
        )
      case "/api/accounts/oauth/revoke":
        let form = String(decoding: syntheticRequestBody(request), as: UTF8.self)
        revokedCurrent =
          form.contains("token=synthetic-new-session") && !form.contains("token=synthetic-rotated")
        return (200, Data())
      default: throw ChatGPTError.message("Unexpected synthetic endpoint")
      }
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.renewSession()
    XCTAssertFalse(connection.activeAccount?.isSignedIn == true)
    let url = try await connection.beginSignIn(accountID: "oaiapp_synthetic")
    nonce = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first(where: {
      $0.name == "nonce"
    })!.value!
    _ = try await finish(url)
    try await waitFor { !connection.isAuthorizing && connection.activeAccount?.isSignedIn == true }
    XCTAssertNil(connection.lastRemoteRevocationConfirmed)
    await connection.disconnect()
    XCTAssertTrue(revokedCurrent)
    XCTAssertEqual(connection.lastRemoteRevocationConfirmed, true)
    connection.shutdown()
  }
  func testRenewalReceiptsAreBoundToSelectedRegistrationAndClearOnSignOut() async throws {
    let rsa = try SyntheticRSA()
    let secrets = AuthMemorySecrets()
    try seed(secrets, now: Date(), clients: ["oaiapp_synthetic", "oaiapp_second"])
    AuthFixtureProtocol.handler = { request in
      if request.url!.path == "/api/accounts/oauth/token" {
        return (200, try self.renewalResponse(rsa))
      }
      if request.url!.path == "/v1/models" { return (200, Data(#"{"models":[]}"#.utf8)) }
      if request.url!.path == "/.well-known/openid-configuration" {
        return (
          200,
          Data(
            #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#
              .utf8)
        )
      }
      return (200, Data())
    }
    let connection = ChatGPTConnection(secrets: secrets, configuration: config())
    await connection.renewSession()
    XCTAssertEqual(connection.sessionRenewalCount, 1)
    await connection.selectAccount("oaiapp_second")
    XCTAssertEqual(connection.sessionRenewalCount, 0)
    XCTAssertNil(connection.lastSessionRenewalAt)
    await connection.selectAccount("oaiapp_synthetic")
    XCTAssertEqual(connection.sessionRenewalCount, 1)
    await connection.disconnect()
    XCTAssertEqual(connection.sessionRenewalCount, 0)
    XCTAssertNil(connection.lastSessionRenewalAt)
    connection.shutdown()
  }

  func testOlderCatalogueSuccessOrFailureCannotOverwriteNewerSameAccountResult() async throws {
    for failOlder in [false, true] {
      DelayedCatalogueProtocol.reset(failOlder: failOlder)
      let secrets = AuthMemorySecrets()
      try seed(secrets, now: Date())
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [DelayedCatalogueProtocol.self]
      let connection = ChatGPTConnection(secrets: secrets, configuration: configuration)
      let older = Task { await connection.refreshModels() }
      try await waitFor { DelayedCatalogueProtocol.requestCount == 1 }
      await connection.refreshModels()
      XCTAssertEqual(connection.models.map(\.slug), ["newer"])
      await older.value
      XCTAssertEqual(connection.models.map(\.slug), ["newer"])
      XCTAssertNil(connection.error)
      XCTAssertEqual(connection.status, "ChatGPT plan connected")
      connection.shutdown()
    }
  }

}
