import FoundationModels

/// Guided-generation schema for the interpret step. The model fills these
/// fields; empty strings mean "not present".
@Generable
struct Interpretation {
  @Guide(description: """
  The single best intent for the question. Must be exactly one of:
  load_status, eta, pod, waybill_lookup, route, stock, invoice,
  vehicle_status, ticket_context, unknown
  """)
  var intent: String

  @Guide(description: "The waybill / consignment / load number if present, otherwise an empty string.")
  var waybill: String

  @Guide(description: "The Freshdesk ticket id if present, otherwise an empty string.")
  var ticketId: String

  @Guide(description: "The customer account reference if present, otherwise an empty string.")
  var account: String
}
