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

  defp stub_login_ok(counter) do
    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("x-freightware", "tok")
      |> Req.Test.json(%{"response" => %{}})
    end)
  end

  test "concurrent callers share a single login (the barrier queues them)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    stub_login_ok(counter)

    store = start_store()
    tasks = for _ <- 1..5, do: Task.async(fn -> TokenStore.token(store) end)
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.all?(results, &(&1 == {:ok, "tok"}))
    # Five callers, one shared login.
    assert Agent.get(counter, & &1) == 1
  end

  test "serves the cached token without re-logging in" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    stub_login_ok(counter)

    store = start_store()
    assert {:ok, "tok"} = TokenStore.token(store)
    assert {:ok, "tok"} = TokenStore.token(store)
    assert Agent.get(counter, & &1) == 1
  end

  test "on a failed login, cools down and fails fast without re-logging in" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(TragarAi.Dovetail.Client, fn conn ->
      Agent.update(counter, &(&1 + 1))
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
    end)

    store = start_store()

    assert {:error, _} = TokenStore.token(store)
    hits = Agent.get(counter, & &1)
    assert hits > 0

    # Inside the cooldown: fail fast, no new login attempts at all.
    assert {:error, :auth_unavailable} = TokenStore.token(store)
    assert Agent.get(counter, & &1) == hits
  end
end
