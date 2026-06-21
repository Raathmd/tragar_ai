import Foundation
import FoundationModels

/// Wraps Apple's on-device model for the two jobs the gateway needs.
/// A fresh session is created per call so requests are stateless.
enum CoreAI {
  static var availabilityMessage: String {
    switch SystemLanguageModel.default.availability {
    case .available:
      return "available"
    case .unavailable(let reason):
      return "unavailable: \(reason)"
    }
  }

  static var isAvailable: Bool {
    if case .available = SystemLanguageModel.default.availability { return true }
    return false
  }

  /// Interpret a free-form question into a structured request.
  /// Returns `["intent": String, "entities": [String: String]]`.
  static func interpret(question: String) async throws -> [String: Any] {
    let instructions = """
    You classify a customer support question for a freight company into a single \
    intent and extract any identifiers. Choose the intent from the allowed list \
    only. Do not answer the question. If unsure, use "unknown".
    """

    let session = LanguageModelSession(instructions: instructions)
    let result = try await session.respond(to: question, generating: Interpretation.self).content

    var entities: [String: String] = [:]
    if !result.waybill.isEmpty { entities["waybill"] = result.waybill }
    if !result.ticketId.isEmpty { entities["ticket_id"] = result.ticketId }
    if !result.account.isEmpty { entities["account"] = result.account }

    return ["intent": normalize(result.intent), "entities": entities]
  }

  /// Phrase already-fetched facts into a short, customer-ready answer.
  static func phrase(intent: String, facts: Any) async throws -> String {
    let instructions = """
    You are a support assistant for a freight company. Write a short, polite, \
    accurate answer to the customer using ONLY the facts provided. Never invent \
    details that are not in the facts. One or two sentences.
    """

    let factsJSON = jsonString(facts)
    let prompt = """
    Intent: \(intent)
    Facts (JSON): \(factsJSON)

    Write the answer.
    """

    let session = LanguageModelSession(instructions: instructions)
    return try await session.respond(to: prompt).content
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  private static func normalize(_ intent: String) -> String {
    intent.lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "_")
  }

  private static func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let str = String(data: data, encoding: .utf8)
    else {
      return "\(value)"
    }
    return str
  }
}
