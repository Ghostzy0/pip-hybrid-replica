import Combine
import CryptoKit
import Foundation
import Security

public struct ChatGPTAccount: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let clientID: String
  public let subject: String
  public let email: String?
  public let displayName: String
  public var planEnabled: Bool
  public var isSignedIn: Bool
  public var expiresAt: Date?
  public var label: String { (email ?? displayName) + " · " + String(clientID.suffix(8)) }
}

struct ChatGPTTokenSet: Codable, Sendable {
  var accessToken: String
  var refreshToken: String?
  var idToken: String
  var scopes: [String]
  var expiresAt: Date
  var earliestRefreshAt: Date?
}
private struct ChatGPTRegistration: Codable, Sendable {
  var account: ChatGPTAccount
  var tokens: ChatGPTTokenSet?
}
private struct ChatGPTSavedState: Codable {
  var version = 1
  var activeID: String?
  var registrations: [ChatGPTRegistration]
}

/// Public fields used in the browser, with sensitive request values deliberately omitted from descriptions.
public struct ChatGPTAuthorizationAttempt: CustomStringConvertible, Sendable {
  public let state: String
  public let nonce: String
  public let verifier: String
  public let redirectURI: URL
  public let requestedClientID: String
  let expectedSubject: String?
  let accountID: String?
  let hostID: String
  let idTokenHint: String?
  let loginHint: String?
  public var description: String { "ChatGPT authorization attempt (values redacted)" }
  public init(
    redirectURI: URL, hostID: String, issuedClientID: String? = nil,
    expectedSubject: String? = nil, accountID: String? = nil,
    idTokenHint: String? = nil, loginHint: String? = nil
  ) throws {
    guard redirectURI.scheme == "http", redirectURI.host == "127.0.0.1",
      redirectURI.path == "/auth/callback",
      (1...65_535).contains(redirectURI.port ?? 0), redirectURI.query == nil,
      redirectURI.fragment == nil,
      redirectURI.user == nil, redirectURI.password == nil, !hostID.isEmpty,
      hostID.utf8.count <= 512
    else { throw ChatGPTError.message("Invalid local sign-in configuration.") }
    if let issuedClientID { try Self.validateIssuedClientID(issuedClientID) }
    self.redirectURI = redirectURI
    self.hostID = hostID
    self.expectedSubject = expectedSubject
    self.accountID = accountID
    self.requestedClientID = issuedClientID ?? "dynamic_agent_client"
    self.idTokenHint = idTokenHint
    self.loginHint = loginHint
    state = try Self.randomValue()
    nonce = try Self.randomValue()
    verifier = try Self.randomValue()
  }
  // Listener must know state before its dynamically assigned port; replacing the callback does not rotate security values.
  init(copying original: ChatGPTAuthorizationAttempt, redirectURI: URL) {
    state = original.state
    nonce = original.nonce
    verifier = original.verifier
    self.redirectURI = redirectURI
    requestedClientID = original.requestedClientID
    expectedSubject = original.expectedSubject
    accountID = original.accountID
    hostID = original.hostID
    idTokenHint = original.idTokenHint
    loginHint = original.loginHint
  }
  public func authorizationURL() -> URL {
    var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
    var fields: [String: String] = [
      "client_id": requestedClientID, "ext_agent_host_id": hostID,
      "response_type": "code", "redirect_uri": redirectURI.absoluteString,
      "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
      "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
      "code_challenge_method": "S256",
      "code_challenge": IDTokenValidator.encodeBase64URL(
        Data(SHA256.hash(data: Data(verifier.utf8)))),
    ]
    if requestedClientID == "dynamic_agent_client" {
      fields["agent_name_hint"] = PipAppIdentity.displayName
    }
    if let idTokenHint { fields["id_token_hint"] = idTokenHint }
    if let loginHint { fields["login_hint"] = loginHint }
    components.queryItems = fields.keys.sorted().map { URLQueryItem(name: $0, value: fields[$0]) }
    return components.url!
  }
  public func issuedClientID(from callback: OAuthCallbackResult) throws -> String {
    if requestedClientID != "dynamic_agent_client" {
      guard callback.clientID == nil || callback.clientID == requestedClientID else {
        throw ChatGPTError.message(
          "The callback changed the selected ChatGPT registration. Existing credentials are unchanged."
        )
      }
      return requestedClientID
    }
    guard let clientID = callback.clientID else {
      throw ChatGPTError.message(
        "ChatGPT did not issue a client registration. Start a fresh sign-in.")
    }
    try Self.validateIssuedClientID(clientID)
    return clientID
  }
  private static func validateIssuedClientID(_ value: String) throws {
    guard value != "dynamic_agent_client",
      value.range(of: "^[A-Za-z0-9_-]{6,256}$", options: .regularExpression) != nil
    else { throw ChatGPTError.message("Invalid ChatGPT client registration.") }
  }
  private static func randomValue() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ChatGPTError.message("Secure random generation failed. No sign-in was started.")
    }
    return IDTokenValidator.encodeBase64URL(Data(bytes))
  }
}

@MainActor public final class ChatGPTConnection: ObservableObject {
  @Published public private(set) var accounts: [ChatGPTAccount] = []
  @Published public private(set) var activeAccountID: String?
  @Published public private(set) var status = "Not connected"
  @Published public private(set) var error: String?
  @Published public private(set) var models: [ChatGPTModel] = []
  @Published public private(set) var isAuthorizing = false
  @Published public private(set) var isRenewingSession = false
  @Published public private(set) var lastSessionRenewalAt: Date?
  @Published public private(set) var sessionRenewalCount = 0
  @Published public private(set) var lastRenewalVerifiedFreshIdentity: Bool?
  @Published public private(set) var lastRemoteRevocationConfirmed: Bool?
  @Published public private(set) var lastRemoteRevocationStatus: Int?
  private let secrets: any SecretStore
  private let http: ChatGPTHTTPClient
  private let now: () -> Date
  private var records: [ChatGPTRegistration] = []
  private var storageReady = true
  private var listener: OAuthCallbackListener?
  private var authorizationID = UUID()
  private var authorizationTask: Task<Void, Never>?
  private var unvalidatedClientID: String?
  private var credentialEpochs: [String: UUID] = [:]
  private var refreshTasks: [String: Task<ChatGPTRegistration, Error>] = [:]
  private var disconnecting = Set<String>()
  private var catalogueRequestID = UUID()
  private var statusIntentID = UUID()
  private var renewalIntentID = UUID()
  private var pendingInvalidations = Set<String>()
  private var pendingRevocationTokens: [String: (token: String, epoch: UUID)] = [:]
  private var disconnectingEpochs: [String: UUID] = [:]
  private var revocationReceipts: [String: (confirmed: Bool, status: Int?)] = [:]
  private var renewalReceipts: [String: (at: Date, count: Int, freshIdentity: Bool)] = [:]
  private var generationID = UUID()
  private var generationTask: Task<Void, Error>?
  private static let recordsKey = "registrations.v1"
  public var activeAccount: ChatGPTAccount? { accounts.first { $0.id == activeAccountID } }
  /// Earliest provider-permitted renewal, if supplied. Never inferred from a usage limit.
  public var nextSessionRenewalAt: Date? {
    records.first(where: { $0.account.id == activeAccountID })?.tokens?.earliestRefreshAt
  }
  public var canRenewSession: Bool {
    guard storageReady, !isAuthorizing, !isRenewingSession, generationTask == nil,
      let id = activeAccountID, !disconnecting.contains(id),
      let tokens = records.first(where: { $0.account.id == id })?.tokens,
      tokens.refreshToken != nil
    else { return false }
    return tokens.earliestRefreshAt.map { $0 <= now() } ?? true
  }
  /// Explicit native action: renew protected credentials without exporting them or sending chat text.
  public func renewSession() async {
    guard canRenewSession, let id = activeAccountID else {
      if !isRenewingSession {
        error =
          "This session cannot renew yet. Wait until its permitted renewal time or sign in again."
      }
      return
    }
    let epoch = credentialEpochs[id]
    let intent = UUID()
    renewalIntentID = intent
    statusIntentID = UUID()
    isRenewingSession = true
    error = nil
    status = "Renewing ChatGPT session…"
    defer { isRenewingSession = false }
    do {
      _ = try await renewedRegistration(for: id)
      try Task.checkCancellation()
      guard activeAccountID == id, credentialEpochs[id] == epoch, renewalIntentID == intent,
        !disconnecting.contains(id)
      else {
        return
      }
      status =
        activeAccount?.planEnabled == true
        ? "ChatGPT session renewed" : "Session renewed · plan usage not enabled"
    } catch {
      guard activeAccountID == id, renewalIntentID == intent else { return }
      self.error = Self.safeMessage(error)
      if storageReady && activeAccount?.isSignedIn == true {
        status = "ChatGPT session renewal incomplete"
      }
    }
  }

  public init(
    secrets: any SecretStore = KeychainSecretStore(service: PipAppIdentity.chatGPTService),
    configuration: URLSessionConfiguration = .ephemeral, now: @escaping () -> Date = Date.init
  ) {
    self.secrets = secrets
    self.now = now
    http = ChatGPTHTTPClient(configuration: configuration)
    statusIntentID = UUID()
    do { try loadProtectedStorage() } catch {
      storageReady = false
      models = []
      self.error =
        "Protected ChatGPT credentials could not be opened. Unlock your Keychain and retry; existing credentials are preserved."
      status = "Protected storage unavailable"
    }
  }
  public var protectedStorageAvailable: Bool { storageReady }
  /// Re-read after an explicit user-initiated Keychain unlock. This store remains noninteractive.
  public func reloadProtectedStorage() throws {
    guard !isAuthorizing, generationTask == nil, refreshTasks.isEmpty, disconnecting.isEmpty else {
      throw ChatGPTError.message(
        "Finish the current ChatGPT operation before reopening protected storage.")
    }
    statusIntentID = UUID()
    do { try loadProtectedStorage() } catch {
      storageReady = false
      models = []
      self.error =
        "Protected ChatGPT credentials could not be opened. Existing credentials are preserved."
      status = "Protected storage unavailable"
      throw ChatGPTError.message(
        "Protected ChatGPT credentials could not be opened. Unlock your Keychain and retry.")
    }
  }
  private func loadProtectedStorage() throws {
    var loaded = [ChatGPTRegistration]()
    var active: String?
    if let data = try secrets.read(Self.recordsKey) {
      guard data.count <= 2_000_000 else {
        throw ChatGPTError.message("Saved provider credentials are too large.")
      }
      let saved = try JSONDecoder().decode(ChatGPTSavedState.self, from: data)
      guard saved.version == 1, saved.registrations.count <= 30,
        Set(saved.registrations.map(\.account.id)).count == saved.registrations.count,
        saved.registrations.allSatisfy({
          $0.account.id == $0.account.clientID && $0.account.clientID != "dynamic_agent_client"
            && !$0.account.subject.isEmpty
        }),
        saved.activeID == nil
          || saved.registrations.contains(where: { $0.account.id == saved.activeID })
      else { throw ChatGPTError.message("Saved ChatGPT registrations could not be validated.") }
      loaded = saved.registrations
      active = saved.activeID
    }
    if !pendingInvalidations.isEmpty {
      for index in loaded.indices where pendingInvalidations.contains(loaded[index].account.id) {
        loaded[index].tokens = nil
        loaded[index].account.isSignedIn = false
        loaded[index].account.planEnabled = false
        loaded[index].account.expiresAt = nil
      }
      // An explicit unlock retry must durably clear quarantined credentials before use resumes.
      try persist(loaded, active: active)
      pendingInvalidations.removeAll()
    }
    renewalReceipts.removeAll()
    revocationReceipts.removeAll()
    pendingRevocationTokens.removeAll()
    records = loaded
    activeAccountID = active
    credentialEpochs = Dictionary(uniqueKeysWithValues: loaded.map { ($0.account.id, UUID()) })
    models = []
    publishAccounts()
    storageReady = true
    error = nil
    status = activeAccount?.isSignedIn == true ? "ChatGPT connected" : "Sign in to ChatGPT"
  }
  public func beginSignIn(accountID: String? = nil) async throws -> URL {
    guard storageReady else {
      throw ChatGPTError.message(
        "Protected credential storage is unavailable. Unlock your Keychain and reopen Pip Hybrid.")
    }
    guard disconnecting.isEmpty else {
      throw ChatGPTError.message(
        "Wait for ChatGPT sign-out to finish before starting another sign-in.")
    }
    renewalIntentID = UUID()
    statusIntentID = UUID()
    cancelSignIn()
    cancelGeneration()
    let id = UUID()
    authorizationID = id
    error = nil
    isAuthorizing = true
    status = "Preparing ChatGPT sign-in…"
    do {
      let existing: ChatGPTRegistration?
      if let accountID {
        guard let found = records.first(where: { $0.account.id == accountID }) else {
          throw ChatGPTError.message("Choose a saved ChatGPT registration or add a new account.")
        }
        existing = found
      } else {
        existing = nil
      }
      let hostID: String
      if let data = try secrets.read("host-id.v1"), let saved = String(data: data, encoding: .utf8),
        saved.hasPrefix("urn:uuid:"), saved.utf8.count <= 100
      {
        hostID = saved
      } else {
        hostID = "urn:uuid:" + UUID().uuidString.lowercased()
        try secrets.write(Data(hostID.utf8), for: "host-id.v1")
      }
      let preliminary = try ChatGPTAuthorizationAttempt(
        redirectURI: URL(string: "http://127.0.0.1:1/auth/callback")!, hostID: hostID,
        issuedClientID: existing?.account.clientID ?? unvalidatedClientID,
        expectedSubject: existing?.account.subject,
        accountID: existing?.account.id, idTokenHint: existing?.tokens?.idToken,
        loginHint: existing?.account.email)
      let listener = OAuthCallbackListener(state: preliminary.state)
      self.listener = listener
      let callback = try await listener.start { [weak self] result in
        Task { @MainActor [weak self] in
          guard let self, self.authorizationID == id else { return }
          self.authorizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishSignIn(result, preliminary: preliminary, attemptID: id)
          }
        }
      }
      guard authorizationID == id else { throw CancellationError() }
      // Save the exact selected callback for exchange; preliminary carries state/PKCE only.
      pendingAttempt = ChatGPTAuthorizationAttempt(copying: preliminary, redirectURI: callback)
      status = "Waiting for ChatGPT in your browser…"
      return pendingAttempt!.authorizationURL()
    } catch {
      if authorizationID == id {
        isAuthorizing = false
        listener?.cancel()
        listener = nil
        status = "ChatGPT sign-in could not start"
        self.error = Self.safeMessage(error)
      }
      throw error
    }
  }
  private var pendingAttempt: ChatGPTAuthorizationAttempt?
  public func cancelSignIn() {
    authorizationID = UUID()
    authorizationTask?.cancel()
    authorizationTask = nil
    listener?.cancel()
    listener = nil
    pendingAttempt = nil
    if isAuthorizing {
      status = activeAccount?.isSignedIn == true ? "ChatGPT connected" : "Sign-in cancelled"
    }
    isAuthorizing = false
  }
  private func finishSignIn(
    _ result: Result<OAuthCallbackResult, Error>, preliminary: ChatGPTAuthorizationAttempt,
    attemptID: UUID
  ) async {
    guard authorizationID == attemptID, let attempt = pendingAttempt,
      attempt.state == preliminary.state
    else { return }
    do {
      let callback = try result.get()
      guard callback.error == nil else {
        throw ChatGPTError.message(
          "ChatGPT consent was declined. Your existing connection is unchanged.")
      }
      guard let code = callback.code else {
        throw ChatGPTError.message("ChatGPT did not return an authorization code.")
      }
      let clientID = try attempt.issuedClientID(from: callback)
      if attempt.requestedClientID == "dynamic_agent_client" { unvalidatedClientID = clientID }
      status = "Validating ChatGPT connection…"
      let (data, response) = try await http.form(
        URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
        fields: [
          "grant_type": "authorization_code", "client_id": clientID, "code": code,
          "code_verifier": attempt.verifier,
          "redirect_uri": attempt.redirectURI.absoluteString,
          "resource": "https://api.openai.com/v1",
        ])
      guard response.statusCode == 200 else {
        throw ChatGPTServiceFailure.make(
          status: response.statusCode, data: data,
          requestID: response.value(forHTTPHeaderField: "x-request-id"))
      }
      let tokens = try Self.tokenSet(data: data, previous: nil, now: now())
      let jwks = try await http.json("https://auth.openai.com/.well-known/jwks.json")
      let identity = try IDTokenValidator.validate(
        tokens.idToken, jwks: jwks, clientID: clientID, nonce: attempt.nonce,
        expectedSubject: attempt.expectedSubject, now: now())
      try Task.checkCancellation()
      guard authorizationID == attemptID else { return }
      if let existing = records.first(where: { $0.account.id == clientID }),
        existing.account.subject != identity.subject
      {
        throw ChatGPTError.message(
          "The ChatGPT registration belongs to another saved identity. Existing credentials are unchanged."
        )
      }
      let account = ChatGPTAccount(
        id: clientID, clientID: clientID, subject: identity.subject, email: identity.email,
        displayName: identity.name ?? identity.email ?? "ChatGPT account",
        planEnabled: tokens.scopes.contains("chatgpt.tokens.use.direct"), isSignedIn: true,
        expiresAt: tokens.expiresAt)
      let record = ChatGPTRegistration(account: account, tokens: tokens)
      var updated = records
      updated.removeAll { $0.account.id == clientID }
      updated.append(record)
      guard updated.count <= 30 else {
        throw ChatGPTError.message(
          "Too many saved ChatGPT accounts. Sign out of an unused account first.")
      }
      try persist(updated, active: clientID)
      records = updated
      activeAccountID = clientID
      credentialEpochs[clientID] = UUID()
      renewalReceipts[clientID] = nil
      revocationReceipts[clientID] = nil
      pendingRevocationTokens[clientID] = nil
      publishAccounts()
      unvalidatedClientID = nil
      isAuthorizing = false
      listener = nil
      pendingAttempt = nil
      authorizationTask = nil
      models = []
      status =
        account.planEnabled
        ? "ChatGPT plan connected" : "Identity connected · plan usage not enabled"
      if account.planEnabled { await refreshModels() }
    } catch {
      guard authorizationID == attemptID else { return }
      isAuthorizing = false
      pendingAttempt = nil
      listener?.cancel()
      listener = nil
      authorizationTask = nil
      status =
        activeAccount?.isSignedIn == true
        ? "Saved ChatGPT connection kept" : "ChatGPT sign-in incomplete"
      self.error = error is CancellationError ? nil : Self.safeMessage(error)
    }
  }
  public func selectAccount(_ id: String) async {
    guard !disconnecting.contains(id), records.contains(where: { $0.account.id == id }) else {
      return
    }
    renewalIntentID = UUID()
    statusIntentID = UUID()
    cancelSignIn()
    cancelGeneration()
    models = []
    error = nil
    do {
      try persist(records, active: id)
      activeAccountID = id
      publishAccounts()
      status =
        activeAccount?.planEnabled == true
        ? "ChatGPT plan connected" : "Sign in or enable plan usage"
      await refreshModels()
    } catch { self.error = Self.safeMessage(error) }
  }
  public func refreshModels() async {
    let requestID = UUID()
    catalogueRequestID = requestID
    models = []
    guard storageReady, let id = activeAccountID, activeAccount?.isSignedIn == true,
      activeAccount?.planEnabled == true
    else { return }
    let epoch = credentialEpochs[id]
    let statusIntent = statusIntentID
    do {
      let token = try await accessToken(for: id)
      try Task.checkCancellation()
      guard catalogueRequestID == requestID, storageReady, activeAccountID == id,
        credentialEpochs[id] == epoch,
        !disconnecting.contains(id),
        activeAccount?.isSignedIn == true, activeAccount?.planEnabled == true
      else { return }
      let data = try await http.json("https://api.openai.com/v1/models", bearer: token)
      guard catalogueRequestID == requestID, storageReady, activeAccountID == id,
        credentialEpochs[id] == epoch,
        !disconnecting.contains(id),
        activeAccount?.isSignedIn == true, activeAccount?.planEnabled == true
      else { return }
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let list = object["models"] as? [[String: Any]], list.count <= 2_000
      else {
        throw ChatGPTError.message(
          "ChatGPT returned an unsupported model catalogue. Try refreshing models later.")
      }
      var seen = Set<String>()
      var selected = [ChatGPTModel]()
      for item in list where item["visibility"] as? String == "list" {
        guard let slug = item["slug"] as? String, !slug.isEmpty, slug.utf8.count <= 200,
          let name = item["display_name"] as? String, !name.isEmpty, name.utf8.count <= 300,
          seen.insert(slug).inserted
        else { continue }
        selected.append(ChatGPTModel(slug: slug, displayName: name))
      }
      models = selected
      if statusIntentID == statusIntent {
        status =
          selected.isEmpty
          ? "Connected · no eligible ChatGPT models listed" : "ChatGPT plan connected"
      }
    } catch {
      if catalogueRequestID == requestID, activeAccountID == id, credentialEpochs[id] == epoch,
        statusIntentID == statusIntent
      {
        self.error = Self.safeMessage(error)
      }
    }
  }
  private func accessToken(for id: String) async throws -> String {
    guard storageReady, !disconnecting.contains(id),
      let index = records.firstIndex(where: { $0.account.id == id }),
      let tokens = records[index].tokens
    else { throw ChatGPTError.message("Sign in to this ChatGPT account again.") }
    guard tokens.scopes.contains("chatgpt.tokens.use.direct") else {
      throw ChatGPTError.message(
        "This account has identity sign-in only. Enable ChatGPT plan usage before sending.")
    }
    let result: ChatGPTRegistration
    if refreshTasks[id] != nil || tokens.expiresAt <= now().addingTimeInterval(90) {
      result = try await renewedRegistration(for: id)
    } else {
      return tokens.accessToken
    }
    try Task.checkCancellation()
    guard storageReady, !disconnecting.contains(id), let refreshed = result.tokens,
      records.first(where: { $0.account.id == id })?.tokens?.accessToken == refreshed.accessToken,
      refreshed.scopes.contains("chatgpt.tokens.use.direct")
    else {
      throw ChatGPTError.message("ChatGPT plan usage is not enabled for this session.")
    }
    return refreshed.accessToken
  }
  private func renewedRegistration(for id: String) async throws -> ChatGPTRegistration {
    guard storageReady, !disconnecting.contains(id),
      let original = records.first(where: { $0.account.id == id }), original.tokens != nil
    else {
      throw ChatGPTError.message("Sign in to this ChatGPT account again.")
    }
    if let task = refreshTasks[id] { return try await task.value }
    let epoch = credentialEpochs[id]
    let task = Task { @MainActor in try await self.refresh(original, epoch: epoch) }
    refreshTasks[id] = task
    defer { refreshTasks[id] = nil }
    return try await task.value
  }
  private func refresh(_ original: ChatGPTRegistration, epoch: UUID?) async throws
    -> ChatGPTRegistration
  {
    let id = original.account.id
    guard let tokens = original.tokens, let refresh = tokens.refreshToken else {
      throw ChatGPTError.message("This ChatGPT session cannot renew. Sign in again.")
    }
    if let earliest = tokens.earliestRefreshAt, earliest > now() {
      throw ChatGPTError.message(
        "ChatGPT asked Pip Hybrid to wait before renewing this session. Try again later.")
    }
    var rotationReceived = false
    do {
      let (data, response) = try await http.form(
        URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
        fields: [
          "grant_type": "refresh_token", "client_id": original.account.clientID,
          "refresh_token": refresh, "resource": "https://api.openai.com/v1",
        ])
      guard response.statusCode == 200 else {
        throw ChatGPTServiceFailure.make(
          status: response.statusCode, data: data,
          requestID: response.value(forHTTPHeaderField: "x-request-id"))
      }
      rotationReceived = true
      if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rotated = object["refresh_token"] as? String, !rotated.isEmpty,
        rotated.utf8.count <= 32_768, let epoch,
        credentialEpochs[id] == epoch || disconnectingEpochs[id] == epoch
      {
        pendingRevocationTokens[id] = (rotated, epoch)
      }
      let replacement = try Self.tokenSet(data: data, previous: tokens, now: now())
      // An omitted ID token retains the previously validated identity as a login hint.
      // Any supplied ID token, including a repeated value, must pass current validation.
      let suppliedIdentity =
        (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id_token"] != nil
      if suppliedIdentity {
        let jwks = try await http.json("https://auth.openai.com/.well-known/jwks.json")
        _ = try IDTokenValidator.validate(
          replacement.idToken, jwks: jwks, clientID: original.account.clientID, nonce: nil,
          expectedSubject: original.account.subject, now: now())
      }
      try Task.checkCancellation()
      guard storageReady, !disconnecting.contains(id), credentialEpochs[id] == epoch else {
        throw CancellationError()
      }
      var updated = original
      updated.tokens = replacement
      updated.account.planEnabled = replacement.scopes.contains("chatgpt.tokens.use.direct")
      updated.account.expiresAt = replacement.expiresAt
      var list = records
      guard let index = list.firstIndex(where: { $0.account.id == id }) else {
        throw CancellationError()
      }
      list[index] = updated
      try persist(list, active: activeAccountID)
      records = list
      if pendingRevocationTokens[id]?.epoch == epoch { pendingRevocationTokens[id] = nil }
      renewalReceipts[id] = (now(), (renewalReceipts[id]?.count ?? 0) + 1, suppliedIdentity)
      publishAccounts()
      if activeAccountID == id && !updated.account.planEnabled { models = [] }
      return updated
    } catch {
      let unusable =
        (error as? ChatGPTServiceFailure).map {
          [
            "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
            "refresh_token_invalid", "refresh_token_invalidated", "refresh_token_reused",
          ].contains($0.code ?? "")
        } ?? false
      if unusable || rotationReceived, credentialEpochs[id] == epoch {
        // A confirmed unusable or rotated token must never remain usable in memory,
        // even when a locked Keychain prevents persisting its removal.
        if let index = records.firstIndex(where: { $0.account.id == id }) {
          pendingInvalidations.insert(id)
          records[index].tokens = nil
          records[index].account.isSignedIn = false
          records[index].account.planEnabled = false
          records[index].account.expiresAt = nil
          credentialEpochs[id] = UUID()
          if activeAccountID == id { models = [] }
          publishAccounts()
          do {
            try persist(records, active: activeAccountID)
            pendingInvalidations.remove(id)
          } catch {
            storageReady = false
            if activeAccountID == id { status = "Protected session update needs attention" }
            throw ChatGPTError.message(
              "The renewed session could not be safely saved. Session use has stopped. Unlock Keychain and sign in again; saved credentials must not be reused."
            )
          }
          if activeAccountID == id { status = "ChatGPT session ended · sign in again" }
        }
      }
      throw error
    }
  }

  static func tokenSet(data: Data, previous: ChatGPTTokenSet?, now: Date = Date()) throws
    -> ChatGPTTokenSet
  {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let access = object["access_token"] as? String, !access.isEmpty, access.utf8.count <= 32_768,
      let tokenType = object["token_type"] as? String, tokenType.lowercased() == "bearer",
      let expires = object["expires_in"] as? NSNumber, CFGetTypeID(expires) != CFBooleanGetTypeID(),
      (1...86_400).contains(expires.doubleValue)
    else {
      throw ChatGPTError.message(
        "ChatGPT returned an invalid token response. No credentials were replaced.")
    }
    let idToken = object["id_token"] as? String ?? previous?.idToken
    guard let idToken, !idToken.isEmpty, idToken.utf8.count <= 32_768 else {
      throw ChatGPTError.message("ChatGPT did not return a signed identity token.")
    }
    let scopes: [String]
    if let raw = object["scope"] as? String, raw.utf8.count <= 4_096 {
      scopes = raw.split(separator: " ").map(String.init)
    } else if let previous {
      scopes = previous.scopes
    } else {
      throw ChatGPTError.message("ChatGPT did not return the granted permissions.")
    }
    if previous?.refreshToken != nil && object["refresh_token"] as? String == nil {
      throw ChatGPTError.message(
        "ChatGPT renewed access without a replacement renewable session. Sign in again; the old token set was not replaced."
      )
    }
    let refresh = object["refresh_token"] as? String
    if scopes.contains("offline_access") && refresh == nil {
      throw ChatGPTError.message("ChatGPT did not return the requested renewable session.")
    }
    guard refresh == nil || (!refresh!.isEmpty && refresh!.utf8.count <= 32_768) else {
      throw ChatGPTError.message("ChatGPT returned an invalid renewable session.")
    }
    var earliest: Date?
    if let raw = object["earliest_refresh_at"] {
      guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
        value.doubleValue.isFinite, value.doubleValue > 0
      else {
        throw ChatGPTError.message("ChatGPT returned an invalid session renewal time.")
      }
      earliest = Date(timeIntervalSince1970: value.doubleValue)
    }
    return ChatGPTTokenSet(
      accessToken: access, refreshToken: refresh, idToken: idToken, scopes: scopes,
      expiresAt: now.addingTimeInterval(expires.doubleValue), earliestRefreshAt: earliest)
  }
  public func disconnect() async {
    guard let id = activeAccountID, let original = records.first(where: { $0.account.id == id }),
      disconnecting.insert(id).inserted
    else { return }
    let originalEpoch = credentialEpochs[id]
    disconnectingEpochs[id] = originalEpoch
    defer {
      disconnecting.remove(id)
      disconnectingEpochs[id] = nil
    }
    renewalIntentID = UUID()
    statusIntentID = UUID()
    cancelSignIn()
    cancelGeneration()
    models = []
    let epoch = UUID()
    credentialEpochs[id] = epoch
    let pendingRotation = refreshTasks[id]
    status = "Signing out of ChatGPT…"
    pendingInvalidations.insert(id)
    renewalReceipts[id] = nil
    // Disable use immediately, before any remote rotation/discovery/revocation await.
    if let index = records.firstIndex(where: { $0.account.id == id }) {
      records[index].tokens = nil
      records[index].account.isSignedIn = false
      records[index].account.planEnabled = false
      records[index].account.expiresAt = nil
      publishAccounts()
      do {
        try persist(records, active: activeAccountID)
        pendingInvalidations.remove(id)
      } catch {
        storageReady = false
        self.error =
          "Protected credential removal needs attention. Session use has stopped; unlock Keychain to safely clear saved credentials."
      }
    }
    // A rotating exchange already admitted by the provider must settle so its newest
    // renewable token, rather than the consumed predecessor, can be revoked.
    _ = try? await pendingRotation?.value
    let pending = pendingRevocationTokens.removeValue(forKey: id)
    let refresh =
      (pending?.epoch == originalEpoch || original.tokens == nil)
      ? (pending?.token ?? original.tokens?.refreshToken) : original.tokens?.refreshToken
    var result = revocationReceipts[id]
    if let refresh {
      result = await revoke(refresh, clientID: original.account.clientID)
      revocationReceipts[id] = result
    }
    guard credentialEpochs[id] == epoch else { return }
    if let index = records.firstIndex(where: { $0.account.id == id }) {
      records[index].tokens = nil
      records[index].account.isSignedIn = false
      records[index].account.planEnabled = false
      records[index].account.expiresAt = nil
    }
    pendingInvalidations.insert(id)
    do {
      try persist(records, active: activeAccountID)
      pendingInvalidations.remove(id)
      // Do not restore a different protected-storage failure automatically.
      if activeAccountID == id {
        status =
          result?.confirmed == true
          ? "Signed out of ChatGPT" : "Signed out locally · remote revocation unconfirmed"
        error =
          result?.confirmed == true
          ? nil
          : "Remote revocation was not confirmed. Disconnect Pip Hybrid in ChatGPT Settings to end access remotely."
      }
    } catch {
      storageReady = false
      if activeAccountID == id {
        status = "Sign-out needs attention"
        self.error =
          "The local credential update failed. Session use is blocked in this process. Unlock Keychain and retry clearing; deletion across restart is not confirmed. Disconnect Pip Hybrid in ChatGPT Settings."
      }
    }
    publishAccounts()
  }
  private func revoke(_ refresh: String, clientID: String) async -> (confirmed: Bool, status: Int?)
  {
    var status: Int?
    do {
      let data = try await http.json("https://auth.openai.com/.well-known/openid-configuration")
      guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        document["issuer"] as? String == IDTokenValidator.issuer,
        let raw = document["revocation_endpoint"] as? String, let url = URL(string: raw),
        ChatGPTHTTPClient.allowed(url), url.path == "/api/accounts/oauth/revoke"
      else {
        return (false, nil)
      }
      for attempt in 0..<3 {
        do {
          let (body, response) = try await http.form(
            url,
            fields: [
              "token": refresh,
              "token_type_hint": "refresh_token", "client_id": clientID,
            ])
          status = response.statusCode
          if status == 200 { return (body.isEmpty, status) }
          guard (500...599).contains(response.statusCode), attempt < 2 else {
            return (false, status)
          }
        } catch {
          guard !(error is CancellationError), !Task.isCancelled, attempt < 2 else {
            return (false, status)
          }
        }
        try await Task.sleep(nanoseconds: attempt == 0 ? 250_000_000 : 750_000_000)
      }
    } catch { return (false, status) }
    return (false, status)
  }
  public func generate(
    model: String, messages: [RuntimeMessage], onDelta: @escaping @MainActor (String) -> Void
  ) async throws {
    guard storageReady, generationTask == nil, let accountID = activeAccountID,
      activeAccount?.planEnabled == true,
      models.contains(where: { $0.slug == model })
    else {
      throw ChatGPTError.message(
        "Choose an eligible model from the connected ChatGPT account before sending.")
    }
    let epoch = credentialEpochs[accountID]
    let id = UUID()
    generationID = id
    let body = try ChatGPTResponseParser.requestBody(model: model, messages: messages)
    let task = Task { @MainActor in
      let token = try await self.accessToken(for: accountID)
      try Task.checkCancellation()
      guard self.generationID == id, self.activeAccountID == accountID,
        self.credentialEpochs[accountID] == epoch, self.activeAccount?.isSignedIn == true,
        self.activeAccount?.planEnabled == true
      else { throw CancellationError() }
      var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
      request.httpMethod = "POST"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
      request.httpBody = body
      let (bytes, response) = try await self.http.session.bytes(for: request)
      guard let response = response as? HTTPURLResponse, response.url == request.url else {
        throw ChatGPTError.message("Unexpected ChatGPT stream destination.")
      }
      if response.statusCode != 200 {
        var data = Data()
        for try await byte in bytes {
          if data.count >= 131_072 { break }
          data.append(byte)
        }
        throw ChatGPTServiceFailure.make(
          status: response.statusCode, data: data,
          requestID: response.value(forHTTPHeaderField: "x-request-id"))
      }
      var framer = ChatGPTSSEFramer()
      var total = 0
      var completed = false
      for try await byte in bytes {
        try Task.checkCancellation()
        guard self.generationID == id, self.activeAccountID == accountID,
          self.credentialEpochs[accountID] == epoch, self.activeAccount?.isSignedIn == true,
          self.activeAccount?.planEnabled == true
        else { throw CancellationError() }
        total += 1
        guard total <= 4_000_000 else {
          throw ChatGPTError.message(
            "The ChatGPT stream exceeded this app's safe response size. Your partial answer is kept."
          )
        }
        if let data = try framer.append(byte) {
          switch try ChatGPTResponseParser.parse(data) {
          case .delta(let text): onDelta(text)
          case .completed: completed = true
          case .other: break
          }
        }
        if completed || framer.sawDone { break }
      }
      guard completed else {
        throw ChatGPTError.message(
          "ChatGPT disconnected before response.completed. Your partial answer is kept.")
      }
    }
    generationTask = task
    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      if generationID == id { generationTask = nil }
    } catch {
      if generationID == id { generationTask = nil }
      throw error
    }
  }
  public func cancelGeneration() {
    generationID = UUID()
    generationTask?.cancel()
    generationTask = nil
  }
  public func shutdown() {
    renewalIntentID = UUID()
    statusIntentID = UUID()
    cancelSignIn()
    cancelGeneration()
    for task in refreshTasks.values { task.cancel() }
  }
  private func persist(_ records: [ChatGPTRegistration], active: String?) throws {
    let data = try JSONEncoder().encode(ChatGPTSavedState(activeID: active, registrations: records))
    guard data.count <= 2_000_000 else {
      throw ChatGPTError.message("Protected ChatGPT credentials exceeded the supported size.")
    }
    try secrets.write(data, for: Self.recordsKey)
    guard try secrets.read(Self.recordsKey) == data else {
      throw ChatGPTError.message("Protected session storage could not confirm its saved update.")
    }
  }
  private func publishAccounts() {
    let revocation = activeAccountID.flatMap { revocationReceipts[$0] }
    lastRemoteRevocationConfirmed = revocation?.confirmed
    lastRemoteRevocationStatus = revocation?.status
    let receipt = activeAccountID.flatMap { renewalReceipts[$0] }
    lastSessionRenewalAt = receipt?.at
    sessionRenewalCount = receipt?.count ?? 0
    lastRenewalVerifiedFreshIdentity = receipt?.freshIdentity
    accounts = records.map { record in
      var account = record.account
      account.isSignedIn = record.tokens != nil
      account.planEnabled = record.tokens?.scopes.contains("chatgpt.tokens.use.direct") == true
      account.expiresAt = record.tokens?.expiresAt
      return account
    }
  }
  private static func safeMessage(_ error: Error) -> String {
    if let error = error as? ChatGPTError { return error.localizedDescription }
    if let error = error as? ChatGPTServiceFailure { return error.localizedDescription }
    if error is CancellationError {
      return "Cancelled. Existing ChatGPT credentials are unchanged."
    }
    return
      "The ChatGPT connection could not finish. Check the network or protected storage and try again; no API billing fallback was used."
  }
}
