defmodule TragarAi.Dovetail.TokenStoreTest do
  use ExUnit.Case, async: false

  alias TragarAi.Dovetail.TokenStore

  setup do
    Req.Test.set_req_test_to_shared()
    :ok
  end

  defp start_store do
    {:ok, pid} = TokenStore.start_link(name: :"ts_#{System.unique_integer([:positive])}")
    pid
  end

  test "keeps concurrent callers queued across retries until a token is generated" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # Login fails twice (500), then succeeds — the queued callers should all get
    # the eventual token, not an error on the first failure.
    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if n < 2 do
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      else
        conn
        |> Plug.Conn.put_resp_header("x-freightware", "tok")
        |> Req.Test.json(%{"response" => %{}})
      end
    end)

    store = start_store()

    tasks = for _ <- 1..3, do: Task.async(fn -> TokenStore.token(store) end)
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert results == [{:ok, "tok"}, {:ok, "tok"}, {:ok, "tok"}]
    # One shared login sequence for all three callers: 2 failures + 1 success.
    assert Agent.get(counter, & &1) == 3
  end

  test "replies an error after exhausting retries, then cools down without re-logging" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      Agent.update(counter, &(&1 + 1))
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
    end)

    store = start_store()

    assert {:error, _} = TokenStore.token(store)
    assert Agent.get(counter, & &1) == 3

    # Inside the cooldown: fail fast without starting another login barrier.
    assert {:error, :auth_unavailable} = TokenStore.token(store)
    assert Agent.get(counter, & &1) == 3
  end

  test "serves the cached token without re-logging in" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("x-freightware", "tok")
      |> Req.Test.json(%{"response" => %{}})
    end)

    store = start_store()
    assert {:ok, "tok"} = TokenStore.token(store)
    assert {:ok, "tok"} = TokenStore.token(store)
    assert {:ok, "tok"} = TokenStore.token(store)
    # Only one login — the rest are cache hits.
    assert Agent.get(counter, & &1) == 1
  end
end
