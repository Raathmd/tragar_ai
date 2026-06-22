defmodule TragarAi.CoreAIHttpTest do
  @moduledoc "Verifies the :http contract mapping the Swift sidecar must satisfy."
  use ExUnit.Case, async: false

  alias TragarAi.CoreAI

  setup do
    original = Application.get_env(:tragar_ai, TragarAi.CoreAI)

    Application.put_env(:tragar_ai, TragarAi.CoreAI,
      mode: :http,
      base_url: "http://coreai.test",
      req_options: [plug: {Req.Test, TragarAi.CoreAI}]
    )

    on_exit(fn -> Application.put_env(:tragar_ai, TragarAi.CoreAI, original) end)
    :ok
  end

  test "interpret sends the tool schema and maps intent + known entity keys" do
    Req.Test.stub(TragarAi.CoreAI, fn conn ->
      assert conn.request_path == "/interpret"
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      names = Jason.decode!(raw)["tools"] |> Enum.map(& &1["name"])

      # The capability/function schema is handed to the model.
      assert "load_status" in names
      assert "invoice" in names

      Req.Test.json(conn, %{
        "intent" => "load_status",
        "entities" => %{"waybill" => "4821", "nonsense" => "drop me", "account" => ""}
      })
    end)

    assert {:ok, %{intent: :load_status, entities: entities}} =
             CoreAI.interpret("where is 4821?")

    assert entities == %{waybill: "4821"}
  end

  test "interpret accepts a function-calling tool_call response" do
    Req.Test.stub(TragarAi.CoreAI, fn conn ->
      Req.Test.json(conn, %{
        "tool_call" => %{"name" => "quote_lookup", "arguments" => %{"quote" => "7012"}}
      })
    end)

    assert {:ok, %{intent: :quote_lookup, entities: %{quote: "7012"}}} =
             CoreAI.interpret("show me quote 7012")
  end

  test "an unknown intent string degrades to :unknown" do
    Req.Test.stub(TragarAi.CoreAI, fn conn ->
      Req.Test.json(conn, %{"intent" => "wat", "entities" => %{}})
    end)

    assert {:ok, %{intent: :unknown}} = CoreAI.interpret("???")
  end

  test "phrase returns the answer string" do
    Req.Test.stub(TragarAi.CoreAI, fn conn ->
      assert conn.request_path == "/phrase"
      Req.Test.json(conn, %{"answer" => "Waybill 4821 is in transit."})
    end)

    assert {:ok, "Waybill 4821 is in transit."} =
             CoreAI.phrase(:load_status, %{"waybill_number" => "4821"})
  end
end
