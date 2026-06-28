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

  test "phrase streams tokens via on_chunk and returns the full text" do
    configure(fn conn ->
      ndjson =
        Enum.map_join(
          [
            %{"message" => %{"content" => "Out for "}, "done" => false},
            %{"message" => %{"content" => "delivery."}, "done" => false},
            %{"message" => %{"content" => ""}, "done" => true}
          ],
          "\n",
          &Jason.encode!/1
        )

      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.send_resp(200, ndjson)
    end)

    parent = self()

    {:ok, full} =
      CoreAI.phrase(:load_status, %{"status" => "OND"}, %{}, fn chunk ->
        send(parent, {:tok, chunk})
      end)

    assert full == "Out for delivery."
    assert_received {:tok, "Out for "}
    assert_received {:tok, "delivery."}
  end

  test "phrase uses the main model; reason uses CORE_AI_REASON_MODEL" do
    parent = self()

    Application.put_env(:tragar_ai, CoreAI,
      mode: :ollama,
      model: "fast-model",
      reason_model: "deep-model",
      base_url: "http://ollama.test",
      req_options: [
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:model, Jason.decode!(body)["model"]})
          Req.Test.json(conn, %{"message" => %{"content" => "ok"}})
        end
      ]
    )

    CoreAI.phrase(:load_status, %{"status" => "OND"})
    assert_received {:model, "fast-model"}

    CoreAI.reason("why is the sky blue?")
    assert_received {:model, "deep-model"}
  end

  test "fast prompts send /no_think; reason lets the model think" do
    parent = self()

    Application.put_env(:tragar_ai, CoreAI,
      mode: :ollama,
      model: "qwen3:14b",
      base_url: "http://ollama.test",
      req_options: [
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          system = Jason.decode!(body)["messages"] |> List.first() |> Map.get("content")
          send(parent, {:system, system})
          Req.Test.json(conn, %{"message" => %{"content" => "ok"}})
        end
      ]
    )

    CoreAI.phrase(:load_status, %{"status" => "OND"})
    assert_received {:system, phrase_sys}
    assert phrase_sys =~ "/no_think"

    CoreAI.reason("why is the sky blue?")
    assert_received {:system, reason_sys}
    refute reason_sys =~ "/no_think"
  end

  test "info/0 reports the Ollama provider and the fallback" do
    configure(fn conn -> Req.Test.json(conn, %{}) end)
    info = CoreAI.info()
    assert info.mode == :ollama
    assert info.provider == "Ollama"
    assert info.label =~ "fallback"
  end
end
