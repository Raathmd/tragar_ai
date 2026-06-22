defmodule TragarAi.Assist.ToolsTest do
  @moduledoc "The tool schema is derived from the validator + adapter registry."
  use ExUnit.Case, async: true

  alias TragarAi.Assist.Tools

  test "every allowed intent becomes a typed function with its required entities + source" do
    schema = Tools.schema()
    by_name = Map.new(schema, &{&1["name"], &1})

    # One function per allowed intent.
    assert MapSet.new(Map.keys(by_name)) ==
             MapSet.new(Enum.map(TragarAi.Assist.Validator.allowed_intents(), &to_string/1))

    load = by_name["load_status"]
    assert load["source"] == "FreightWare"
    assert load["parameters"]["required"] == ["waybill"]
    assert load["parameters"]["properties"]["waybill"]["type"] == "string"

    assert by_name["invoice"]["source"] == "Pastel"
    assert by_name["vehicle_status"]["source"] == "FleetIT"
  end
end
