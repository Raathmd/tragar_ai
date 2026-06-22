defmodule TragarAi.QuoteIntake.Server do
  @moduledoc """
  Orchestrates a guided quote conversation: loads/creates the per-ticket
  `Session`, advances the `Flow`, persists, and — once the customer confirms —
  creates the quote in FreightWare.

  The FreightWare module is injectable (`:freightware` opt) so the conversation
  logic can be tested without touching the live API.
  """

  alias TragarAi.QuoteIntake
  alias TragarAi.QuoteIntake.Flow

  @type input :: %{
          required(:ticket_id) => String.t(),
          required(:account) => String.t(),
          optional(:message) => String.t(),
          optional(:requester_email) => String.t()
        }

  @doc """
  Handle one inbound message for a ticket. Returns a map the controller renders
  as JSON: `reply` is the text to post back to the customer.
  """
  @spec handle(input(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle(%{ticket_id: ticket_id, account: account} = input, opts \\ []) do
    fw = Keyword.get(opts, :freightware, TragarAi.Freight)
    message = Map.get(input, :message, "") || ""

    case load(ticket_id) do
      nil -> open(ticket_id, account, input, message)
      %{status: "collecting"} = s -> collect(s, message, fw)
      %{status: "ready"} = s -> confirm(s, message, fw)
      %{status: status} = s -> {:ok, result(s, "This quote request is already #{status}.", true)}
    end
  end

  # First message on a ticket — greet and ask the opening question.
  defp open(ticket_id, account, input, message) do
    reply = Flow.opening_question()

    upsert(%{
      ticket_id: ticket_id,
      account_reference: account,
      requester_email: input[:requester_email],
      status: "collecting",
      slots: %{},
      request_text: message,
      last_reply: reply
    })
    |> case do
      {:ok, s} -> {:ok, result(s, reply, false)}
      err -> err
    end
  end

  # Mid-conversation — record the answer, ask the next question or finalize.
  defp collect(session, message, fw) do
    case Flow.advance(session.slots, message) do
      {:ask, slots, question} ->
        save(session, %{slots: slots, last_reply: question})
        |> ok(question, false)

      {:ready, slots, _summary} ->
        finalize(session, slots, fw)
    end
  end

  # All params gathered — resolve the real service code, get a live rate
  # (best-effort), and ask the customer to confirm.
  defp finalize(session, slots, fw) do
    account = session.account_reference
    {slots, rate} = rate_quote(slots, account, fw)
    summary = Flow.ready_summary(slots, rate)

    save(session, %{slots: slots, status: "ready", last_reply: summary})
    |> ok(summary, false, quote_params: Flow.to_quote_params(slots, account), rate: rate)
  end

  # Map the service words → real FreightWare code, then quick-quote for a rate.
  # Both are best-effort: failures leave the flow intact (no code / no price).
  defp rate_quote(slots, account, fw) do
    slots =
      case safe(fn -> fw.resolve_service_type(slots["service"]) end) do
        {:ok, st} -> Map.put(slots, "service_code", st["code"])
        _ -> slots
      end

    params = Flow.to_quote_params(slots, account)

    rate =
      case safe(fn -> fw.quick_quote(params) end) do
        {:ok, rates} -> pick_rate(rates, slots["service_code"])
        _ -> nil
      end

    {if(rate, do: Map.put(slots, "rate", rate), else: slots), rate}
  end

  defp pick_rate(rates, code) when is_list(rates) and rates != [] do
    rate = Enum.find(rates, &(&1["service_type"] == code)) || hd(rates)
    rate["total_charge"] || rate["freight_charge"]
  end

  defp pick_rate(_, _), do: nil

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # Quote is ready — interpret ACCEPT / REJECT.
  defp confirm(session, message, fw) do
    params = Flow.to_quote_params(session.slots, session.account_reference)

    case Flow.decision(message) do
      :accept ->
        create_quote(session, params, fw)

      :reject ->
        save(session, %{status: "rejected", last_reply: rejected_msg()})
        |> ok(rejected_msg(), true)

      :unclear ->
        {:ok,
         result(session, "Please reply ACCEPT to create the quote, or REJECT to cancel.", false)}
    end
  end

  defp create_quote(session, params, fw) do
    case fw.create_quote(params) do
      {:ok, quote} ->
        number = quote["quote_number"] || quote[:quote_number]
        reply = "Quote #{number} has been created in FreightWare. An agent will confirm shortly."

        save(session, %{status: "accepted", quote_number: number, last_reply: reply})
        |> ok(reply, true, quote_number: number, quote: quote)

      {:error, reason} ->
        {:ok,
         result(
           session,
           "I couldn't create the quote in FreightWare just now (#{inspect(reason)}). An agent will follow up.",
           false
         )}
    end
  end

  defp rejected_msg, do: "No problem — I've cancelled this quote request."

  # ── persistence + result shaping ─────────────────────────────────────────────

  defp load(ticket_id) do
    case QuoteIntake.get_session(ticket_id) do
      {:ok, session} -> session
      _ -> nil
    end
  end

  defp upsert(attrs), do: QuoteIntake.upsert_session(attrs)

  defp save(session, changes) do
    attrs =
      session
      |> Map.take([
        :ticket_id,
        :account_reference,
        :requester_email,
        :status,
        :slots,
        :request_text,
        :quote_number
      ])
      |> Map.merge(changes)

    upsert(attrs)
  end

  defp ok(result, reply, complete?, extra \\ [])

  defp ok({:ok, session}, reply, complete?, extra),
    do: {:ok, result(session, reply, complete?, extra)}

  defp ok(err, _reply, _complete?, _extra), do: err

  defp result(session, reply, complete?, extra \\ []) do
    Map.merge(
      %{
        ticket_id: session.ticket_id,
        account: session.account_reference,
        status: session.status,
        reply: reply,
        complete: complete?
      },
      Map.new(extra)
    )
  end
end
