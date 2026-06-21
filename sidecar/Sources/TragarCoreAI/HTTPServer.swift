import Foundation
import Network

/// A minimal HTTP/1.1 server for localhost JSON — no external dependencies.
/// Low-volume (the agent console), one request per connection, `Connection: close`.
final class HTTPServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "tragar.coreai.http")

  init(port: UInt16) throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
  }

  func start() {
    listener.newConnectionHandler = { [weak self] conn in
      conn.start(queue: self!.queue)
      self?.receive(conn, buffer: Data())
    }
    listener.start(queue: queue)
  }

  private func receive(_ conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buf = buffer
      if let data { buf.append(data) }

      if let request = HTTPRequest.parse(buf) {
        Task { await self.respond(conn, request) }
      } else if isComplete || error != nil {
        conn.cancel()
      } else {
        self.receive(conn, buffer: buf)
      }
    }
  }

  private func respond(_ conn: NWConnection, _ request: HTTPRequest) async {
    switch (request.method, request.path) {
    case ("GET", "/"):
      send(conn, 200, ["status": "ok", "model": CoreAI.availabilityMessage])

    case ("POST", "/interpret"):
      guard CoreAI.isAvailable else {
        send(conn, 503, ["error": CoreAI.availabilityMessage])
        return
      }

      do {
        let dict = json(request.body)
        let question = dict["question"] as? String ?? ""
        let result = try await CoreAI.interpret(question: question)
        send(conn, 200, result)
      } catch {
        send(conn, 500, ["error": "\(error)"])
      }

    case ("POST", "/phrase"):
      guard CoreAI.isAvailable else {
        send(conn, 503, ["error": CoreAI.availabilityMessage])
        return
      }

      do {
        let dict = json(request.body)
        let intent = dict["intent"] as? String ?? "unknown"
        let facts = dict["facts"] ?? [:]
        let answer = try await CoreAI.phrase(intent: intent, facts: facts)
        send(conn, 200, ["answer": answer])
      } catch {
        send(conn, 500, ["error": "\(error)"])
      }

    default:
      send(conn, 404, ["error": "not found"])
    }
  }

  private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }

  private func send(_ conn: NWConnection, _ status: Int, _ body: [String: Any]) {
    let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)

    let header =
      "HTTP/1.1 \(status) \(reason(status))\r\n" +
      "Content-Type: application/json\r\n" +
      "Content-Length: \(payload.count)\r\n" +
      "Connection: close\r\n\r\n"

    var out = Data(header.utf8)
    out.append(payload)
    conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
  }

  private func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default: return "OK"
    }
  }
}

/// A parsed request, or nil if more bytes are still needed.
struct HTTPRequest {
  let method: String
  let path: String
  let body: Data

  static func parse(_ data: Data) -> HTTPRequest? {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }

    let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
    guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

    let lines = headerStr.components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").split(separator: " ")
    guard parts.count >= 2 else { return nil }

    var contentLength = 0
    for line in lines.dropFirst() {
      let kv = line.split(separator: ":", maxSplits: 1)
      if kv.count == 2,
         kv[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length" {
        contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
      }
    }

    let bodyStart = headerEnd.upperBound
    let available = data.distance(from: bodyStart, to: data.endIndex)
    if available < contentLength { return nil }

    let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: contentLength))
    return HTTPRequest(method: String(parts[0]), path: String(parts[1]), body: body)
  }
}
