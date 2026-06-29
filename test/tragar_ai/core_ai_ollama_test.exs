defmodule TragarAi.CoreAIOllamaTest do
  @moduledoc "The :ollama provider — direct qwen calls, with stub fallback when qwen is down."
  use ExUnit.Case, async: false

  alias TragarAi.CoreAI

  setup do
    original = Application.get_env(:tragar_ai, CoreAI)

    on_exit(fn ->
      Application.put_env(:tragar_ai, CoreAI, original)
      :persistent_term.erase({CoreAI, :active_reason_model})
    end)

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

  test "interpret returns multiple lookups when the model splits the question" do
    configure(fn conn ->
      Req.Test.json(conn, %{
        "message" => %{
          "content" =>
            ~s({"intents":[{"intent":"load_status","entities":{"waybill":"WB1"}},{"intent":"eta","entities":{"waybill":"WB1"}},{"intent":"load_status","entities":{"waybill":"WB2"}}]})
        }
      })
    end)

    assert {:ok, %{intents: intents, intent: :load_status, entities: %{waybill: "WB1"}}} =
             CoreAI.interpret("status and eta of WB1, and where is WB2?")

    # One entry per lookup — the same intent may repeat with different entities.
    # No "scope" in the JSON → defaults to "one".
    assert intents == [
             %{intent: :load_status, entities: %{waybill: "WB1"}, scope: "one"},
             %{intent: :eta, entities: %{waybill: "WB1"}, scope: "one"},
             %{intent: :load_status, entities: %{waybill: "WB2"}, scope: "one"}
           ]
  end

  test "a single-object interpret reply still yields a one-element intents list" do
    configure(fn conn ->
      Req.Test.json(conn, %{
        "message" => %{"content" => ~s({"intent":"load_status","entities":{"waybill":"WB1"}})}
      })
    end)

    assert {:ok, %{intent: :load_status, entities: %{waybill: "WB1"}, intents: [one]}} =
             CoreAI.interpret("where is WB1?")

    assert one == %{intent: :load_status, entities: %{waybill: "WB1"}, scope: "one"}
  end

  test "interpret carries an explicit scope=all for a broad request" do
    configure(fn conn ->
      Req.Test.json(conn, %{
        "message" => %{
          "content" => ~s({"intents":[{"intent":"load_status","entities":{"waybill":"WB1"},"scope":"all"}]})
        }
      })
    end)

    assert {:ok, %{scope: "all", intents: [%{scope: "all"}]}} =
             CoreAI.interpret("tell me everything about WB1")
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

  test "reasoning model is runtime-switchable; switching to fast unloads the deep model" do
    parent = self()

    Application.put_env(:tragar_ai, CoreAI,
      mode: :ollama,
      model: "fast-model",
      reason_model: "deep-model",
      base_url: "http://ollama.test",
      req_options: [
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          d = Jason.decode!(body)
          send(parent, {:req, d["model"], d["keep_alive"]})
          Req.Test.json(conn, %{"message" => %{"content" => "ok"}})
        end
      ]
    )

    # Default: with a deep reason_model configured, reason uses it (long-running,
    # thinking on); phrase always uses the fast model.
    CoreAI.reason("q")
    assert_received {:req, "deep-model", _}
    CoreAI.phrase(:load_status, %{"status" => "OND"})
    assert_received {:req, "fast-model", _}

    # Switch to fast → reason now uses the fast model; fires an immediate unload
    # (keep_alive: 0) of the deep model.
    assert :ok = CoreAI.set_reasoning("fast-model")
    assert_received {:req, "deep-model", 0}
    CoreAI.reason("q")
    assert_received {:req, "fast-model", _}

    # Switch back to deep → reason uses the deep model again.
    assert :ok = CoreAI.set_reasoning("deep-model")
    CoreAI.reason("q")
    assert_received {:req, "deep-model", _}

    # An unknown model is rejected.
    assert {:error, :unknown_model} = CoreAI.set_reasoning("bogus")
  end

  test "interpret prompt exposes capabilities grouped by source (so the model can route)" do
    parent = self()

    Application.put_env(:tragar_ai, CoreAI,
      mode: :ollama,
      model: "m",
      base_url: "http://ollama.test",
      req_options: [
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          system = Jason.decode!(body)["messages"] |> List.first() |> Map.get("content")
          send(parent, {:system, system})

          Req.Test.json(conn, %{
            "message" => %{"content" => ~s({"intents":[{"intent":"route","entities":{"waybill":"WB1"}}]})}
          })
        end
      ]
    )

    CoreAI.interpret("call vantage for WB1")
    assert_received {:system, sys}
    assert sys =~ "Vantage"
    assert sys =~ "route"
    assert sys =~ "FreightWare"
    # The named-source routing instruction is present.
    assert sys =~ "names a source"
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

  test "cloud tier serves phrase when Ollama is down — redacted out, rehydrated back" do
    parent = self()

    Application.put_env(:tragar_ai, CoreAI,
      mode: :ollama,
      model: "fast",
      base_url: "http://ollama.test",
      # Ollama is down → the chain must fall through to the cloud tier.
      req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 500, "down") end],
      cloud_enabled: true,
      cloud_api_key: "sk-ant-test",
      cloud_url: "http://anthropic.test/v1/messages",
      cloud_req_options: [
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:cloud_body, body})
          Req.Test.json(conn, %{
            "content" => [%{"type" => "text", "text" => "Your waybill [[1]] was delivered."}]
          })
        end
      ]
    )

    facts = %{"waybill_number" => "0006794936FC", "status" => "OND"}
    {:ok, answer} = CoreAI.phrase(:load_status, facts, %{question: "Where is waybill 0006794936FC?"})

    # The answer is rehydrated — real value back, no leftover token.
    assert answer =~ "0006794936FC"
    refute answer =~ "[[1]]"

    # The payload that left for Anthropic carried only the token, never the waybill.
    assert_received {:cloud_body, body}
    refute body =~ "0006794936FC"
    assert body =~ "[[1]]"
  end

  test "with the cloud flag off, an Ollama-down phrase falls to the stub (no cloud call)" do
    parent = self()

    Application.put_env(:tragar_ai, CoreAI,
      mode: :ollama,
      model: "fast",
      base_url: "http://ollama.test",
      req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 500, "down") end],
      cloud_enabled: false,
      cloud_api_key: "sk-ant-test",
      cloud_url: "http://anthropic.test/v1/messages",
      cloud_req_options: [
        plug: fn conn ->
          send(parent, :cloud_called)
          Req.Test.json(conn, %{})
        end
      ]
    )

    assert {:ok, _} = CoreAI.phrase(:load_status, %{"status" => "OND"}, %{})
    refute_received :cloud_called
  end
end
