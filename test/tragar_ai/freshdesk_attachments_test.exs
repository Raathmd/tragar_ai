defmodule TragarAi.FreshdeskAttachmentsTest do
  use ExUnit.Case, async: true

  # Fake Freshdesk client returning a ticket with an attachment on the body and
  # another on a reply/note.
  defmodule FakeClient do
    def get_ticket(_id, _params) do
      {:ok,
       %{
         "id" => 55,
         "attachments" => [
           %{
             "id" => 1,
             "name" => "load.pdf",
             "content_type" => "application/pdf",
             "size" => 1000,
             "attachment_url" => "https://files.example/load.pdf"
           }
         ],
         "conversations" => [
           %{
             "attachments" => [
               %{
                 "id" => 2,
                 "name" => "manifest.xlsx",
                 "content_type" =>
                   "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                 "size" => 2000,
                 "attachment_url" => "https://files.example/manifest.xlsx"
               }
             ]
           },
           %{"attachments" => []}
         ]
       }}
    end
  end

  test "aggregates attachments from the ticket body and its conversations" do
    assert {:ok, list} = TragarAi.Freshdesk.ticket_attachments("55", client: FakeClient)

    names = Enum.map(list, & &1.name)
    assert "load.pdf" in names
    assert "manifest.xlsx" in names
    assert length(list) == 2
    assert Enum.all?(list, &is_binary(&1.url))
  end
end
