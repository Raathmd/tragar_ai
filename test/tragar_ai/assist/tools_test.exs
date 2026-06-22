defmodule TragarAi.Assist.ToolsTest do
  @moduledoc "The tool schema is derived from the validator + adapter registry."
  use ExUnit.Case, async: true

  alias TragarAi.Assist.Tools

  test "read tools cover every allowed intent, typed with source" do
    by_name = Map.new(Tools.schema(), &{&1["name"], &1})
    reads = for {n, t} <- by_name, t["action"] == "read", into: %{}, do: {n, t}

    assert MapSet.new(Map.keys(reads)) ==
             MapSet.new(Enum.map(TragarAi.Assist.Validator.allowed_intents(), &to_string/1))

    load = reads["load_status"]
    assert load["source"] == "FreightWare"
    assert load["parameters"]["required"] == ["waybill"]
    assert reads["invoice"]["source"] == "Pastel"
    assert reads["vehicle_status"]["source"] == "FleetIT"
  end

  test "change actions are listed (not executed by the assistant) with source functions" do
    by_name = Map.new(Tools.schema(), &{&1["name"], &1})
    change = by_name["change_quote"]

    assert change["action"] == "change"
    assert change["execution"] == "performed_by_agent_in_source_app"
    assert "accept_quote" in change["source_functions"]
    assert change["where"] =~ "FreightWare"
  end
end
