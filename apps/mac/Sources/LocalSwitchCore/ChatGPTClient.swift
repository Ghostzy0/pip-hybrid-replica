import Foundation

public struct ChatGPTModel: Identifiable, Equatable, Sendable {
  public var id: String { slug }
  public let slug: String
  public let displayName: String
}

public struct ChatGPTServiceFailure: LocalizedError {
  public let status: Int
  public let code: String?
  public let requestID: String?
  public let bodyShape: String
  public var errorDescription: String? {
    let context = code.map { " (\($0))" } ?? ""
    switch code {
    case "subscription_sharing_usage_limit_exceeded":
      return
        "This app's ChatGPT plan allowance was reached. Review ChatGPT Settings → Usage. Your partial answer is kept; no API billing fallback was used."
    case "subscription_sharing_user_not_eligible":
      return
        "ChatGPT plan use is unavailable for this account or workspace. Your local models are still available."
    case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
      return
        "ChatGPT could not check plan availability. Try again later; your account is preserved."
    case "subscription_sharing_unsupported_capability":
      return
        "This request uses a capability unsupported by ChatGPT plan sharing. No billing route was changed."
    default:
      if status == 401 {
        return
          "ChatGPT did not accept this session\(context). Sign in again if the connection has been revoked."
      }
      if status == 403 {
        return
          "ChatGPT denied this request\(context). Check the selected account, workspace and plan permissions."
      }
      return
        "ChatGPT could not complete this request (HTTP \(status))\(context). Your partial answer and account are preserved."
    }
  }
  static func make(status: Int, data: Data, requestID: String? = nil) -> ChatGPTServiceFailure {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let error = object?["error"] as? [String: Any]
    let raw = error?["code"] as? String ?? object?["error"] as? String
    let code = raw.flatMap {
      $0.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) == nil ? nil : $0
    }
    return ChatGPTServiceFailure(
      status: status, code: code, requestID: requestID.map { String($0.prefix(256)) },
      bodyShape: error != nil
        ? "error-object" : object?["detail"] != nil ? "detail" : data.isEmpty ? "empty" : "other")
  }
}

private final class ChatGPTNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// Fixed official HTTPS endpoints, ephemeral cookies/cache and no redirects or retries.
final class ChatGPTHTTPClient {
  let session: URLSession
  init(configuration: URLSessionConfiguration = .ephemeral) {
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 300
    session = URLSession(
      configuration: configuration, delegate: ChatGPTNoRedirectDelegate(), delegateQueue: nil)
  }
  static func allowed(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil,
      url.query == nil,
      url.port == nil || url.port == 443, let host = url.host
    else { return false }
    if host == "auth.openai.com" {
      return [
        "/.well-known/openid-configuration", "/.well-known/jwks.json", "/api/accounts/oauth/token",
        "/api/accounts/oauth/revoke",
      ].contains(url.path)
    }
    return host == "api.openai.com" && ["/v1/models", "/v1/responses"].contains(url.path)
  }
  func load(_ request: URLRequest, maximumBytes: Int = 2_000_000) async throws -> (
    Data, HTTPURLResponse
  ) {
    guard let url = request.url, Self.allowed(url) else {
      throw ChatGPTError.message("The provider destination is not approved.")
    }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, response.url == url else {
      throw ChatGPTError.message("Unexpected ChatGPT network response.")
    }
    if response.expectedContentLength > maximumBytes {
      throw ChatGPTError.message("ChatGPT returned more data than expected.")
    }
    var data = Data()
    data.reserveCapacity(min(maximumBytes, 65_536))
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maximumBytes else {
        throw ChatGPTError.message("ChatGPT returned more data than expected.")
      }
      data.append(byte)
    }
    return (data, response)
  }
  func json(_ url: String, bearer: String? = nil) async throws -> Data {
    var request = URLRequest(url: URL(string: url)!)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await load(request)
    guard response.statusCode == 200 else {
      throw ChatGPTServiceFailure.make(
        status: response.statusCode, data: data,
        requestID: response.value(forHTTPHeaderField: "x-request-id"))
    }
    return data
  }
  func form(_ url: URL, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
    guard Self.allowed(url) else {
      throw ChatGPTError.message("The provider destination is not approved.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.encodeForm(fields)
    return try await load(request, maximumBytes: 131_072)
  }
  static func encodeForm(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return Data(
      fields.keys.sorted().map { key in
        key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[key]!
          .addingPercentEncoding(withAllowedCharacters: allowed)!
      }.joined(separator: "&").utf8)
  }
}

public enum ChatGPTResponseParser {
  public enum Event: Equatable { case delta(String), completed, other }
  public static func parse(_ data: Data) throws -> Event {
    guard data.count <= 524_288,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else {
      throw ChatGPTError.message("ChatGPT returned an invalid event. Your partial answer is kept.")
    }
    switch type {
    case "response.output_text.delta":
      guard let delta = object["delta"] as? String else {
        throw ChatGPTError.message("ChatGPT returned an invalid text event.")
      }
      return .delta(delta)
    case "response.completed":
      guard let response = object["response"] as? [String: Any],
        response["status"] as? String == "completed"
      else { throw ChatGPTError.message("ChatGPT did not confirm completion.") }
      return .completed
    case "response.failed", "error":
      let response = object["response"] as? [String: Any] ?? object
      let error = response["error"] as? [String: Any] ?? object
      let bytes = try JSONSerialization.data(withJSONObject: ["error": error])
      throw ChatGPTServiceFailure.make(status: type == "error" ? 400 : 503, data: bytes)
    case "response.incomplete":
      throw ChatGPTError.message(
        "ChatGPT ended before completing the answer. Your partial text is kept.")
    default: return .other
    }
  }
  public static func requestBody(model: String, messages: [RuntimeMessage]) throws -> Data {
    guard !model.isEmpty, model.utf8.count <= 200, !messages.isEmpty,
      messages.count <= 500, messages.reduce(0, { $0 + $1.content.utf8.count }) <= 100_000,
      messages.allSatisfy({ ["system", "developer", "user", "assistant"].contains($0.role) })
    else { throw ChatGPTError.message("This conversation is too large or invalid for ChatGPT.") }
    let instructions = messages.filter { $0.role == "system" }.map(\.content).joined(
      separator: "\n")
    let input = messages.filter { $0.role != "system" }.map {
      ["role": $0.role, "content": $0.content]
    }
    guard !input.isEmpty else {
      throw ChatGPTError.message("A ChatGPT request needs a user conversation.")
    }
    var body: [String: Any] = ["model": model, "input": input, "store": false, "stream": true]
    if !instructions.isEmpty { body["instructions"] = instructions }
    return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
  }
}

/// Preserves empty SSE lines and fragmented UTF-8. AsyncBytes.lines may omit empty lines.
struct ChatGPTSSEFramer {
  private var line = Data()
  private var eventLines = [String]()
  private var eventBytes = 0
  private var skipLF = false
  private(set) var sawDone = false
  mutating func append(_ byte: UInt8) throws -> Data? {
    if skipLF {
      skipLF = false
      if byte == 10 { return nil }
    }
    if byte == 10 || byte == 13 {
      if byte == 13 { skipLF = true }
      return try finishLine()
    }
    guard line.count < 524_288 else {
      throw ChatGPTError.message("ChatGPT returned an oversized stream line.")
    }
    line.append(byte)
    return nil
  }
  private mutating func finishLine() throws -> Data? {
    guard let text = String(data: line, encoding: .utf8) else {
      throw ChatGPTError.message("ChatGPT returned invalid text encoding.")
    }
    line.removeAll(keepingCapacity: true)
    if text.isEmpty {
      guard !eventLines.isEmpty else { return nil }
      let data = Data(eventLines.joined(separator: "\n").utf8)
      eventLines.removeAll(keepingCapacity: true)
      eventBytes = 0
      return data
    }
    guard text.hasPrefix("data:") else { return nil }
    var value = String(text.dropFirst(5))
    if value.first == " " { value.removeFirst() }
    if value == "[DONE]" {
      sawDone = true
      return nil
    }
    eventBytes += value.utf8.count
    guard eventBytes <= 524_288 else {
      throw ChatGPTError.message("ChatGPT returned an oversized stream event.")
    }
    eventLines.append(value)
    return nil
  }
}
