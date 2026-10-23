import Foundation
import Network

public struct OAuthCallbackResult: Sendable {
  public let code: String?
  public let clientID: String?
  public let error: String?
}

/// HTTP parser intentionally accepts one exact loopback GET route and no body.
public enum OAuthCallbackParser {
  public static func parse(_ request: Data, port: UInt16, expectedState: String) throws
    -> OAuthCallbackResult
  {
    guard request.count <= 16_384, let text = String(data: request, encoding: .utf8),
      text.hasSuffix("\r\n\r\n"), !text.contains("\0")
    else { throw rejected() }
    let lines = text.components(separatedBy: "\r\n")
    let start = lines[0].components(separatedBy: " ")
    guard start.count == 3, start[0] == "GET", start[2] == "HTTP/1.1",
      start[1].hasPrefix("/auth/callback?"), !start[1].hasPrefix("//"),
      let components = URLComponents(string: start[1]), components.path == "/auth/callback",
      components.scheme == nil, components.host == nil, components.fragment == nil
    else { throw rejected() }
    var headers = [String: String]()
    for line in lines.dropFirst() where !line.isEmpty {
      guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let separator = line.firstIndex(of: ":")
      else { throw rejected() }
      let name = String(line[..<separator]).lowercased()
      guard headers[name] == nil else { throw rejected() }
      headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
      headers["content-length"] == nil || headers["content-length"] == "0"
    else { throw rejected() }
    var values = [String: String]()
    for item in components.queryItems ?? [] {
      guard values[item.name] == nil, let value = item.value, value.utf8.count <= 8_192 else {
        throw rejected()
      }
      values[item.name] = value
    }
    guard let state = values["state"], IDTokenValidator.constantEqual(state, expectedState) else {
      throw rejected()
    }
    if let error = values["error"] {
      guard values["code"] == nil, error == "access_denied" else { throw rejected() }
      return OAuthCallbackResult(code: nil, clientID: values["client_id"], error: error)
    }
    guard let code = values["code"], !code.isEmpty, code.utf8.count <= 4_096 else {
      throw rejected()
    }
    return OAuthCallbackResult(code: code, clientID: values["client_id"], error: nil)
  }
  private static func rejected() -> ChatGPTError {
    .message("The sign-in callback did not match the pending request.")
  }
}

/// Binds literal 127.0.0.1, not a wildcard. Stray/malformed requests do not consume the attempt.
final class OAuthCallbackListener: @unchecked Sendable {
  private let queue = DispatchQueue(label: "app.pip.hybrid.mac.oauth-callback")
  private var listener: NWListener?
  private var connections = [UUID: NWConnection]()
  private var timer: DispatchSourceTimer?
  private var accepted = false
  private var completion: (@Sendable (Result<OAuthCallbackResult, Error>) -> Void)?
  private var port: UInt16 = 0
  private var startup: CheckedContinuation<URL, Error>?
  private let state: String
  init(state: String) { self.state = state }
  func start(completion: @escaping @Sendable (Result<OAuthCallbackResult, Error>) -> Void)
    async throws -> URL
  {
    self.completion = completion
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.allowLocalEndpointReuse = false
    let listener = try NWListener(using: parameters, on: .any)
    self.listener = listener
    return try await withCheckedThrowingContinuation { continuation in
      self.startup = continuation
      listener.stateUpdateHandler = { [weak self] status in
        guard let self else { return }
        switch status {
        case .ready:
          guard let startup = self.startup, let port = self.listener?.port?.rawValue else { return }
          self.startup = nil
          self.port = port
          let timer = DispatchSource.makeTimerSource(queue: self.queue)
          timer.schedule(deadline: .now() + 600)
          timer.setEventHandler { [weak self] in
            self?.finish(
              .failure(
                ChatGPTError.message(
                  "ChatGPT sign-in timed out. Your existing connection is unchanged.")))
          }
          self.timer = timer
          timer.resume()
          startup.resume(returning: URL(string: "http://127.0.0.1:\(port)/auth/callback")!)
        case .failed:
          self.finish(
            .failure(
              ChatGPTError.message("The local sign-in listener stopped. Try signing in again.")))
        case .cancelled:
          self.finish(.failure(CancellationError()))
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
      listener.start(queue: queue)
    }
  }
  func cancel() { queue.async { [weak self] in self?.finish(.failure(CancellationError())) } }
  private func receive(_ connection: NWConnection) {
    guard !accepted, connections.count < 8 else {
      connection.cancel()
      return
    }
    guard case .hostPort(let remote, _) = connection.endpoint, remote == .ipv4(.loopback) else {
      connection.cancel()
      return
    }
    let id = UUID()
    connections[id] = connection
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
      connection?.cancel()
      self?.connections[id] = nil
    }
    receivePart(connection, id: id, accumulated: Data())
  }
  private func receivePart(_ connection: NWConnection, id: UUID, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_385 - accumulated.count) {
      [weak self] data, _, ended, error in
      guard let self, !self.accepted else {
        connection.cancel()
        return
      }
      var bytes = accumulated
      if let data { bytes.append(data) }
      guard bytes.count <= 16_384 else {
        self.respond(connection, id: id, accepted: false)
        return
      }
      if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
        do {
          let result = try OAuthCallbackParser.parse(
            bytes, port: self.port, expectedState: self.state)
          self.accepted = true
          self.respond(connection, id: id, accepted: true) { self.finish(.success(result)) }
        } catch { self.respond(connection, id: id, accepted: false) }
      } else if ended || error != nil {
        connection.cancel()
        self.connections[id] = nil
      } else {
        self.receivePart(connection, id: id, accumulated: bytes)
      }
    }
  }
  private func respond(
    _ connection: NWConnection, id: UUID, accepted: Bool, completion: (() -> Void)? = nil
  ) {
    let body =
      accepted
      ? "<!doctype html><meta charset=utf-8><title>Pip Hybrid</title><p>Return to Pip Hybrid to finish connecting. You can close this tab.</p>"
      : "Invalid callback. Return to Pip Hybrid."
    let status = accepted ? "200 OK" : "400 Bad Request"
    let response =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
    connection.send(
      content: Data(response.utf8),
      completion: .contentProcessed { [weak self] _ in
        connection.cancel()
        self?.connections[id] = nil
        completion?()
      })
  }
  private func finish(_ result: Result<OAuthCallbackResult, Error>) {
    if let startup {
      self.startup = nil
      if case .failure(let error) = result {
        startup.resume(throwing: error)
      } else {
        startup.resume(throwing: CancellationError())
      }
    }
    guard let callback = completion else { return }
    completion = nil
    timer?.cancel()
    timer = nil
    listener?.stateUpdateHandler = nil
    listener?.newConnectionHandler = nil
    listener?.cancel()
    listener = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
    callback(result)
  }
}
