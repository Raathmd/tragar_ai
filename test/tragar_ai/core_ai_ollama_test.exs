defmodule TragarAi.CoreAIOllamaTest do
  @moduledoc "The :ollama provider — direct qwen calls, with stub fallback when qwen is down."
  use ExUnit.Case, async: false

  alias TragarAi.CoreAI

  setup do
    original = Application.get_env(:tragar_ai, CoreAI)
    on_exit(fn -> Application.put_env(:tragar_ai, CoreAI, original) end)
    :ok
  end

  defp configure(plug) do
    Application.put_env(:tragar_ai, CoreAI,
      mode: :ollama,
      model: "qwen3:30b",
      base_url: "http://ollama.test",
      req_options: [plug: plug]
    )
  end

  test "interpret calls Ollama /api/chat and constrains to an allowed intent" do
    configure(fn conn ->
      assert conn.request_path == "/api/chat"

      Req.Test.json(conn, %{
        "message" => %{
          "role" => "assistant",
          "content" => ~s({"intent":"load_status","entities":{"waybill":"WB1","bogus":"x"}})
        }
      })
    end)

    assert {:ok, %{intent: :load_status, entities: entities}} = CoreAI.interpret("where is WB1?")
    # Only known entity keys survive; an off-list intent would become :unknown.
    assert entities == %{waybill: "WB1"}
  end

  test "an intent qwen invents that we don't allow collapses to :unknown" do
    configure(fn conn ->
      Req.Test.json(conn, %{
        "message" => %{"content" => ~s({"intent":"launch_rocket","entities":{}})}
      })
    end)

    assert {:ok, %{intent: :unknown}} = CoreAI.interpret("do something weird")
  end

  test "phrase calls Ollama and strips any thinking preamble" do
    configure(fn conn ->
      Req.Test.json(conn, %{
        "message" => %{"content" => "<think>let me check</think>Your parcel is out for delivery."}
      })
    end)

    assert {:ok, "Your parcel is out for delivery."} =
             CoreAI.phrase(:load_status, %{"status" => "OND"})
  end

  test "falls back to the deterministic stub when Ollama is down" do
    configure(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    # qwen errored — the stub answers instead of the whole loop failing.
    assert {:ok, %{intent: :service_types}} =
             CoreAI.interpret("what service types do you offer?")
  end

  test "info/0 reports the Ollama provider and the fallback" do
    configure(fn conn -> Req.Test.json(conn, %{}) end)
    info = CoreAI.info()
    assert info.mode == :ollama
    assert info.provider == "Ollama"
    assert info.label =~ "fallback"
  end
end
