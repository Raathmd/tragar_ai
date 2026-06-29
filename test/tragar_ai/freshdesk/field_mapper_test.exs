defmodule TragarAi.Freshdesk.FieldMapperTest do
  use ExUnit.Case, async: true

  alias TragarAi.Freshdesk.FieldMapper

  defp text(name, label),
    do: %{"name" => name, "label" => label, "type" => "custom_text"}

  defp dropdown(name, label, choices),
    do: %{"name" => name, "label" => label, "type" => "custom_dropdown", "choices" => choices}

  defp default(name, label),
    do: %{"name" => name, "label" => label, "type" => "default_#{name}"}

  test "fills a custom text field from a same-named fact" do
    fields = [text("cf_waybill_number", "Waybill number")]
    facts = %{"waybill_number" => "4821", "status" => "In transit"}

    assert FieldMapper.custom_field_updates(fields, facts) == %{"cf_waybill_number" => "4821"}
  end

  test "matches via the alias table (status_description fact → 'Waybill status' field)" do
    fields = [text("cf_waybill_status", "Waybill status")]
    facts = %{"status_description" => "In transit"}

    assert FieldMapper.custom_field_updates(fields, facts) == %{
             "cf_waybill_status" => "In transit"
           }
  end

  test "fills a dropdown only when the value matches an allowed choice" do
    fields = [dropdown("cf_waybill_status", "Waybill status", ["In transit", "Delivered"])]

    assert FieldMapper.custom_field_updates(fields, %{"status" => "in transit"}) == %{
             "cf_waybill_status" => "In transit"
           }

    # Value outside the allowed choices is skipped, never sent.
    assert FieldMapper.custom_field_updates(fields, %{"status" => "Lost in space"}) == %{}
  end

  test "ignores default (non-custom) fields, including assignment" do
    fields = [
      default("status", "Status"),
      default("group", "Group"),
      default("agent", "Agent"),
      text("cf_account", "Account")
    ]

    facts = %{"status" => "Open", "account_reference" => "ITD02"}

    # Only the custom account field is filled; status/group/agent untouched.
    assert FieldMapper.custom_field_updates(fields, facts) == %{"cf_account" => "ITD02"}
  end

  test "skips fields with no matching fact and blank fact values" do
    fields = [text("cf_eta", "ETA"), text("cf_account", "Account")]
    facts = %{"account_reference" => "", "unrelated" => "x"}

    assert FieldMapper.custom_field_updates(fields, facts) == %{}
  end

  test "accepts atom-keyed facts" do
    fields = [text("cf_account", "Account")]

    assert FieldMapper.custom_field_updates(fields, %{account_reference: "ITD02"}) == %{
             "cf_account" => "ITD02"
           }
  end
end
