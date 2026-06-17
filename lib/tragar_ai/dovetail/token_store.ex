defmodule TragarAi.Dovetail.TokenStore do
  @moduledoc """
  Caches the Dovetail/FreightWare auth token.

  FreightWare authentication returns a token in the `X-FreightWare` response
  header (see `TragarAi.Dovetail.Client.login/0`). That token is then sent on
  every subsequent request. Rather than logging in on every call, this
  GenServer caches the token and refreshes it lazily — on first use, after a
  configurable TTL, or when a caller reports it as rejected (e.g. on a 401).
  """

  use GenServer

  require Logger

  # Refresh proactively a little before the server-side session is likely to
  # lapse. FreightWare sessions are typically valid for ~30 min; we refresh at
  # 25 to stay comfortably inside that window.
  @ttl_ms :timer.minutes(25)

  defmodule State do
    @moduledoc false
    defstruct token: nil, fetched_at_ms: nil
  end

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `{:ok, token}` using the cached token when fresh, otherwise logging
  in to obtain a new one. Returns `{:error, reason}` if authentication fails.
  """
  @spec token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def token(server \\ __MODULE__) do
    GenServer.call(server, :token, 30_000)
  end

  @doc """
  Forces a fresh login on the next `token/1` call. Call this when a request is
  rejected with an auth error so the next attempt re-authenticates.
  """
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    GenServer.cast(server, :invalidate)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %State{}}

  @impl true
  def handle_call(:token, _from, state) do
    if fresh?(state) do
      {:reply, {:ok, state.token}, state}
    else
      case TragarAi.Dovetail.Client.login() do
        {:ok, token} ->
          {:reply, {:ok, token}, %State{token: token, fetched_at_ms: now_ms()}}

        {:error, reason} = error ->
          Logger.error("Dovetail login failed: #{inspect(reason)}")
          {:reply, error, %State{}}
      end
    end
  end

  @impl true
  def handle_cast(:invalidate, _state), do: {:noreply, %State{}}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp fresh?(%State{token: nil}), do: false

  defp fresh?(%State{fetched_at_ms: fetched_at}) when is_integer(fetched_at),
    do: now_ms() - fetched_at < @ttl_ms

  defp fresh?(_), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)
end
