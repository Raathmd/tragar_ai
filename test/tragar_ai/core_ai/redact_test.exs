defmodule TragarAi.CoreAI.RedactTest do
  use ExUnit.Case, async: true

  alias TragarAi.CoreAI.Redact

  test "redacts entity + PII fact values and rehydrates them back" do
    facts = %{
      "waybill_number" => "0006794936FC",
      "consignee_name" => "Acme Pty Ltd",
      "status" => "OND"
    }

    entities = %{waybill: "0006794936FC", account: "ACC1001"}
    question = "Where is waybill 0006794936FC for ACC1001?"

    map = Redact.build(Redact.secrets(question, facts, entities) ++ Redact.identifiers(question))

    prompt = "Facts: #{Jason.encode!(facts)}\nAccount: ACC1001"
    redacted = Redact.apply(prompt, map)

    # No real private value leaves in the redacted text.
    refute redacted =~ "0006794936FC"
    refute redacted =~ "Acme Pty Ltd"
    refute redacted =~ "ACC1001"
    assert redacted =~ "[["

    # The non-PII status code is preserved (not treated as private).
    assert redacted =~ "OND"

    # The model echoes tokens; restore puts the real values back.
    token = Enum.find_value(map, fn {t, v} -> v == "0006794936FC" && t end)
    assert Redact.restore("Your waybill #{token} was delivered.", map) =~ "0006794936FC"
  end

  test "identifiers/1 catches free-text identifiers a customer might type" do
    ids = Redact.identifiers("track 0006794936FC, account ITD02, email me at jo@x.co")
    assert "0006794936FC" in ids
    assert "ITD02" in ids
    assert "jo@x.co" in ids
  end
end
