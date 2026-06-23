defmodule TragarAi.Vantage.TokenStore do
  @moduledoc """
  Caches the Vantage `Authentication-Token`.

  Vantage authenticates via `POST /api/auth/login` and returns a token that is
  then sent on every request in the `Authentication-Token` header. This GenServer
  caches the token and refreshes it lazily — on first use, after a TTL, or when a
  caller reports it rejected (e.g. on a 401).
  """

  use GenServer
  require Logger

  @ttl_ms :timer.minutes(50)

  defmodule State do
    @moduledoc false
    defstruct token: nil, fetched_at_ms: nil
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def token(server \\ __MODULE__), do: GenServer.call(server, :token, 30_000)

  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__), do: GenServer.cast(server, :invalidate)

  @impl true
  def init(_opts), do: {:ok, %State{}}

  @impl true
  def handle_call(:token, _from, state) do
    if fresh?(state) do
      {:reply, {:ok, state.token}, state}
    else
      case TragarAi.Vantage.Client.login() do
        {:ok, token} ->
          {:reply, {:ok, token}, %State{token: token, fetched_at_ms: now_ms()}}

        {:error, reason} = error ->
          Logger.error("Vantage login failed: #{inspect(reason)}")
          {:reply, error, %State{}}
      end
    end
  end

  @impl true
  def handle_cast(:invalidate, _state), do: {:noreply, %State{}}

  defp fresh?(%State{token: nil}), do: false

  defp fresh?(%State{fetched_at_ms: at}) when is_integer(at), do: now_ms() - at < @ttl_ms
  defp fresh?(_), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)
end
