defmodule TragarAi.Assist.EntitiesTest do
  use ExUnit.Case, async: true

  alias TragarAi.Assist.Entities

  test "entity_for/1 maps a reference key to its domain entity" do
    assert Entities.entity_for(%{waybill: "DIS0124440"}) == :waybill
    assert Entities.entity_for(%{account: "ACC1001"}) == :account
    assert Entities.entity_for(%{quote: "7012"}) == :quote
    assert Entities.entity_for(%{ticket_id: "55"}) == :ticket
    assert Entities.entity_for(%{}) == nil
    assert Entities.entity_for(%{waybill: ""}) == nil
  end

  test "group/1 returns the cross-source capability set for an entity" do
    assert %{param: :waybill, capabilities: caps} = Entities.group(:waybill)
    assert :load_status in caps
    assert :route in caps
    assert Entities.group(:nope) == nil
  end

  test "key/1 extracts the reference value" do
    assert Entities.key(:waybill, %{waybill: "DIS0124440"}) == "DIS0124440"
    assert Entities.key(:account, %{account: "ACC1001"}) == "ACC1001"
  end
end
