import Foundation

let port = UInt16(ProcessInfo.processInfo.environment["PORT"] ?? "") ?? 11434

do {
  let server = try HTTPServer(port: port)
  server.start()
  FileHandle.standardError.write(Data(
    "Tragar Core AI sidecar listening on http://127.0.0.1:\(port) — model \(CoreAI.availabilityMessage)\n".utf8
  ))
  dispatchMain()
} catch {
  FileHandle.standardError.write(Data("Failed to start sidecar: \(error)\n".utf8))
  exit(1)
}
