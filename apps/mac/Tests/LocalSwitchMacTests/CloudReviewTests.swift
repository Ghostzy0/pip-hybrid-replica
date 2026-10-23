import Foundation
import XCTest

@testable import LocalSwitchCore
@testable import LocalSwitchMac

private final class CloudMemorySecrets: SecretStore {
  var values: [String: Data] = [:]
  func read(_ key: String) throws -> Data? { values[key] }
  func write(_ data: Data, for key: String) throws { values[key] = data }
  func remove(_ key: String) throws { values[key] = nil }
}

/// All provider traffic is intercepted; synthetic registrations never reach an external service.
private final class CloudFixtureProtocol: URLProtocol {
  static let lock = NSLock()
  static var requests: [URLRequest] = []
  static let defaultResponseBody =
    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Synthetic answer\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
  static var responseBody = defaultResponseBody
  static func setResponseBody(_ body: String) {
    lock.lock()
    defer { lock.unlock() }
    responseBody = body
  }
  static func snapshot() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
  static func reset() {
    lock.lock()
    requests = []
    responseBody = defaultResponseBody
    lock.unlock()
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var observed = request
    if observed.httpBody == nil, let input = observed.httpBodyStream {
      input.open()
      defer { input.close() }
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while input.hasBytesAvailable {
        let count = input.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        bytes.append(contentsOf: buffer.prefix(count))
      }
      observed.httpBody = bytes
    }
    Self.lock.lock()
    Self.requests.append(observed)
    let stream = Self.responseBody
    Self.lock.unlock()
    let path = request.url!.path
    let body: Data
    let status: Int
    if path == "/v1/models" {
      body = Data(
        #"{"models":[{"slug":"eligible","display_name":"Eligible model","visibility":"list"},{"slug":"alternative","display_name":"Alternative model","visibility":"list"},{"slug":"hidden","display_name":"Hidden model","visibility":"hide"}]}"#
          .utf8)
      status = 200
    } else if path == "/v1/responses" {
      body = Data(stream.utf8)
      status = 200
    } else {
      body = Data(#"{"error":{"code":"unexpected_fixture_request"}}"#.utf8)
      status = 403
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Type": path == "/v1/responses" ? "text/event-stream" : "application/json"
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor final class CloudReviewTests: XCTestCase {
  private var apps: [AppModel] = []
  private var roots: [URL] = []
  private var preferenceSuites: [String] = []
  override func tearDown() {
    apps.forEach { $0.shutdown() }
    apps = []
    roots.forEach { try? FileManager.default.removeItem(at: $0) }
    roots = []
    preferenceSuites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
    preferenceSuites = []
    CloudFixtureProtocol.reset()
    super.tearDown()
  }
  private func makeApp(connected: Bool = true) throws -> AppModel {
    CloudFixtureProtocol.reset()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LocalSwitch-Cloud-" + UUID().uuidString
    ).resolvingSymlinksInPath()
    roots.append(root)
    let suite = "LocalSwitch-CloudTests-" + UUID().uuidString
    preferenceSuites.append(suite)
    let secrets = CloudMemorySecrets()
    if connected {
      let records = ["oaiapp_synthetic", "oaiapp_second"].map { client -> [String: Any] in
        let expiry = Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate
        return [
          "account": [
            "id": client, "clientID": client, "subject": "synthetic-subject",
            "displayName": "Synthetic account", "planEnabled": true, "isSignedIn": true,
            "expiresAt": expiry,
          ],
          "tokens": [
            "accessToken": "synthetic-access", "refreshToken": "synthetic-refresh",
            "idToken": "synthetic-identity",
            "scopes": ["openid", "offline_access", "chatgpt.tokens.use.direct"],
            "expiresAt": expiry,
          ],
        ]
      }
      secrets.values["registrations.v1"] = try JSONSerialization.data(withJSONObject: [
        "version": 1, "activeID": "oaiapp_synthetic", "registrations": records,
      ])
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudFixtureProtocol.self]
    let app = AppModel(
      root: root.appendingPathComponent("Models"), preferences: UserDefaults(suiteName: suite)!,
      historySecrets: CloudMemorySecrets(), chatGPTSecrets: secrets,
      chatGPTConfiguration: configuration)
    apps.append(app)
    XCTAssertTrue(app.historyAvailable)
    return app
  }
  private func eligibleApp() async throws -> AppModel {
    let app = try makeApp()
    await app.chatGPT.refreshModels()
    app.cloudMode = true
    app.selectedChatGPTModel = "eligible"
    app.draft = "Synthetic draft"
    return app
  }
  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Synthetic cloud operation timed out")
  }
  private var responseRequests: [URLRequest] {
    CloudFixtureProtocol.snapshot().filter { $0.url?.path == "/v1/responses" }
  }
  func testConnectedAccountDefaultsToLocalAndCannotSendWithoutLocalModel() throws {
    let app = try makeApp()
    XCTAssertTrue(app.chatGPT.activeAccount?.isSignedIn == true)
    XCTAssertFalse(app.cloudMode)
    XCTAssertTrue(CloudFixtureProtocol.snapshot().isEmpty)
    app.draft = "Synthetic unsent text"
    app.send()
    XCTAssertEqual(app.draft, "Synthetic unsent text")
    XCTAssertTrue(app.messages.isEmpty)
    XCTAssertNil(app.pendingCloudReview)
    XCTAssertTrue(CloudFixtureProtocol.snapshot().isEmpty)
  }
  func testPreparationRequiresListedMetadataAndNeverDispatchesContent() async throws {
    let app = try makeApp()
    app.cloudMode = true
    app.selectedChatGPTModel = "eligible"
    app.draft = "Synthetic retained draft"
    app.prepareCloudReview()
    XCTAssertNil(app.pendingCloudReview)
    XCTAssertEqual(app.draft, "Synthetic retained draft")
    XCTAssertTrue(CloudFixtureProtocol.snapshot().isEmpty)
    await app.chatGPT.refreshModels()
    app.selectedChatGPTModel = "hidden"
    app.prepareCloudReview()
    XCTAssertNil(app.pendingCloudReview)
    app.selectedChatGPTModel = "eligible"
    app.prepareCloudReview()
    let review = try XCTUnwrap(app.pendingCloudReview)
    XCTAssertEqual(review.modelName, "Eligible model")
    XCTAssertEqual(review.messages.last?.content, "Synthetic retained draft")
    XCTAssertEqual(app.draft, "Synthetic retained draft")
    XCTAssertTrue(app.messages.isEmpty)
    XCTAssertTrue(responseRequests.isEmpty)
    XCTAssertEqual(CloudFixtureProtocol.snapshot().map { $0.url!.path }, ["/v1/models"])
  }
  func testDraftContextRouteAndModelChangesInvalidatePreviousApproval() async throws {
    let app = try await eligibleApp()
    let mutations: [(AppModel) -> Void] = [
      { $0.draft = "Changed draft" },
      { $0.messages.append(ChatMessage(role: "user", content: "New prior context")) },
      { $0.cloudMode = false },
      { $0.selectedChatGPTModel = "alternative" },
      { $0.newChat() },
    ]
    for mutate in mutations {
      app.cloudMode = true
      app.selectedChatGPTModel = "eligible"
      app.draft = "Synthetic draft"
      app.prepareCloudReview()
      let review = try XCTUnwrap(app.pendingCloudReview)
      mutate(app)
      XCTAssertNil(app.pendingCloudReview)
      let draftAfterMutation = app.draft
      let countAfterMutation = app.messages.count
      app.approveCloudReview(review)
      XCTAssertEqual(app.draft, draftAfterMutation)
      XCTAssertEqual(app.messages.count, countAfterMutation)
      XCTAssertFalse(app.isBusy)
      XCTAssertTrue(responseRequests.isEmpty)
    }
  }
  func testAccountSwitchRejectsPreviousReviewEvenBeforeUIReconciliation() async throws {
    let app = try await eligibleApp()
    app.prepareCloudReview()
    let review = try XCTUnwrap(app.pendingCloudReview)
    await app.chatGPT.selectAccount("oaiapp_second")
    app.approveCloudReview(review)
    XCTAssertEqual(app.draft, "Synthetic draft")
    XCTAssertTrue(app.messages.isEmpty)
    XCTAssertFalse(app.isBusy)
    XCTAssertTrue(responseRequests.isEmpty)
  }
  func testReviewIncludesInstructionsAndRedactsEveryPriorTurnWithoutEditingLocalHistory()
    async throws
  {
    let app = try await eligibleApp()
    app.messages = [
      ChatMessage(role: "user", content: "Email old@example.com"),
      ChatMessage(role: "assistant", content: "Call +44 7700 900123"),
      ChatMessage(role: "system", content: "Synthetic excluded metadata"),
    ]
    app.draft = "New new@example.com with sk-abcdefghijklmnopqrstuvwxyz123456"
    app.prepareCloudReview(redacted: true)
    let review = try XCTUnwrap(app.pendingCloudReview)
    XCTAssertTrue(review.redacted)
    XCTAssertEqual(review.messages.map(\.role), ["system", "user", "assistant", "user"])
    XCTAssertTrue(review.messages[0].content.contains("You are Pip"))
    XCTAssertTrue(review.messages[0].content.contains("no browsing, file access or tools"))
    XCTAssertEqual(review.findings, 0)
    XCTAssertEqual(review.messages[1].content, "Email [Email address]")
    XCTAssertEqual(review.messages[2].content, "Call [Phone number]")
    XCTAssertTrue(review.messages[3].content.contains("[API key]"))
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: review.body) as? [String: Any])
    XCTAssertEqual(payload["instructions"] as? String, review.messages[0].content)
    XCTAssertEqual(payload["store"] as? Bool, false)
    XCTAssertEqual(payload["stream"] as? Bool, true)
    let raw = String(decoding: review.body, as: UTF8.self)
    for sensitive in [
      "old@example.com", "new@example.com", "7700 900123", "sk-abcdefghijklmnopqrstuvwxyz123456",
    ] { XCTAssertFalse(raw.contains(sensitive)) }
    XCTAssertEqual(app.messages[0].content, "Email old@example.com")
    XCTAssertTrue(app.draft.contains("new@example.com"))
    XCTAssertTrue(responseRequests.isEmpty)
  }
  func testApprovalSendsExactReviewedBodyOnceAndRequiresTerminalCompletion() async throws {
    let app = try await eligibleApp()
    app.prepareCloudReview()
    let review = try XCTUnwrap(app.pendingCloudReview)
    app.approveCloudReview(review)
    XCTAssertNil(app.pendingCloudReview)
    app.approveCloudReview(review)
    try await waitUntil { !app.isBusy }
    XCTAssertEqual(responseRequests.count, 1)
    let request = try XCTUnwrap(responseRequests.first)
    XCTAssertEqual(request.httpBody, review.body)
    XCTAssertEqual(app.messages.last?.content, "Synthetic answer")
    XCTAssertEqual(app.messages.last?.state, "complete")
    XCTAssertEqual(app.messages.last?.route, "chatgpt")
    XCTAssertEqual(app.messages.last?.outboundDigest, review.digest)
    app.approveCloudReview(review)
    XCTAssertEqual(responseRequests.count, 1)
  }
  func testAccountMaintenanceClaimsSynchronouslyAndBlocksCloudReviewUntilFinished() async throws {
    let app = try await eligibleApp()
    let baseline = CloudFixtureProtocol.snapshot().filter { $0.url?.path == "/v1/models" }.count
    app.refreshChatGPTModels()
    app.refreshChatGPTModels()
    XCTAssertTrue(app.isManagingChatGPT)
    XCTAssertFalse(app.canSend)
    app.send()
    XCTAssertNil(app.pendingCloudReview)
    XCTAssertEqual(app.draft, "Synthetic draft")
    XCTAssertTrue(responseRequests.isEmpty)
    try await waitUntil { !app.isManagingChatGPT }
    XCTAssertEqual(
      CloudFixtureProtocol.snapshot().filter { $0.url?.path == "/v1/models" }.count, baseline + 1)
    XCTAssertTrue(app.canSend)
  }
  func testSignOutPreemptsPendingSignInWithoutStaleCancellationError() async throws {
    let app = try await eligibleApp()
    app.startChatGPTSignIn(accountID: nil, openBrowser: false)
    try await waitUntil { app.chatGPT.isAuthorizing }
    app.disconnectChatGPT()
    try await waitUntil { !app.isManagingChatGPT && !app.chatGPT.isAuthorizing }
    XCTAssertNil(app.error)
    XCTAssertFalse(app.cloudMode)
    XCTAssertFalse(app.chatGPT.activeAccount?.isSignedIn == true)
    XCTAssertTrue(responseRequests.isEmpty)
  }
  func testNoAccountCloudSendPreservesDraftAndMakesNoHTTPRequest() throws {
    let app = try makeApp(connected: false)
    app.cloudMode = true
    app.draft = "Synthetic private draft"
    app.send()
    XCTAssertEqual(app.draft, "Synthetic private draft")
    XCTAssertTrue(app.messages.isEmpty)
    XCTAssertNil(app.pendingCloudReview)
    XCTAssertFalse(app.isBusy)
    XCTAssertTrue(CloudFixtureProtocol.snapshot().isEmpty)
  }
  func testQueuedAccountSwitchBeforeGenerationCannotSendApprovedAccountATextAsAccountB()
    async throws
  {
    let app = try await eligibleApp()
    app.prepareCloudReview()
    let review = try XCTUnwrap(app.pendingCloudReview)
    let switching = Task { await app.chatGPT.selectAccount("oaiapp_second") }
    app.approveCloudReview(review)
    await switching.value
    try await waitUntil { !app.isBusy }
    XCTAssertEqual(app.chatGPT.activeAccountID, "oaiapp_second")
    XCTAssertTrue(responseRequests.isEmpty)
    XCTAssertNotEqual(app.messages.last?.state, "complete")
  }

  func testMissingTerminalCompletionKeepsPartialAnswerAndDoesNotClaimSuccess() async throws {
    let app = try await eligibleApp()
    CloudFixtureProtocol.setResponseBody(
      "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial synthetic answer\"}\n\ndata: [DONE]\n\n"
    )
    app.prepareCloudReview()
    app.approveCloudReview(try XCTUnwrap(app.pendingCloudReview))
    try await waitUntil { !app.isBusy }
    XCTAssertEqual(responseRequests.count, 1)
    XCTAssertEqual(app.messages.last?.content, "Partial synthetic answer")
    XCTAssertEqual(app.messages.last?.state, "failed")
    XCTAssertNil(app.completionPulse)
    XCTAssertNotNil(app.error)
  }

}
