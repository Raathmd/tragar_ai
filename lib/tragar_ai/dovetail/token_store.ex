defmodule TragarAi.Dovetail.TokenStore do
  @moduledoc """
  Caches the Dovetail/FreightWare auth token behind a **login barrier**.

  FreightWare issues a single session token per user/station (see
  `TragarAi.Dovetail.Client.login/0`) and **invalidates the previous session on
  each new login**. So concurrent callers must never each log in — a second login
  would invalidate the first caller's token mid-flight. This GenServer guarantees
  at most one login is ever in flight: while it runs, every caller that needs a
  token parks on that single login and then shares its result. A valid cached
  token is served immediately, with no queueing at all — the barrier only engages
  when a new token is actually needed (first use, TTL expiry, or invalidation).

  The login runs in a short-lived task *off* the GenServer's `handle_call`, so a
  slow/unreachable FreightWare can't freeze the store and time out every caller
  (which previously cascaded into `GenServer.call` timeouts).
  """

  use GenServer

  require Logger

  # Refresh proactively a little before the server-side session (~30 min) lapses.
  @ttl_ms :timer.minutes(25)

  # On a failed login, keep the queued callers parked and retry a few times with a
  # short backoff between attempts (transient wobbles recover transparently). After
  # @max_attempts we give up, reply the error, and enter a cooldown during which new
  # callers fail fast WITHOUT starting another barrier — so a persistent outage
  # doesn't stampede FreightWare with logins.
  @max_attempts 3

  defp retry_backoff_ms,
    do: Application.get_env(:tragar_ai, __MODULE__, [])[:retry_backoff_ms] || 2_000

  defp cooldown_ms,
    do: Application.get_env(:tragar_ai, __MODULE__, [])[:cooldown_ms] || :timer.seconds(30)

  defmodule State do
    @moduledoc false
    # token / fetched_at_ms: the cached session.
    # logging_in?:           a login task is currently in flight (the barrier).
    # waiters:               callers parked until a token is generated.
    # attempts:              login attempts in the current barrier (for the retry cap).
    # failed_at_ms:          when the barrier last gave up (for the cooldown).
    defstruct token: nil,
              fetched_at_ms: nil,
              logging_in?: false,
              waiters: [],
              attempts: 0,
              failed_at_ms: nil
  end

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `{:ok, token}`, serving the cached token when fresh or waiting on the
  single in-flight login otherwise. `{:error, reason}` if authentication fails.
  """
  @spec token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def token(server \\ __MODULE__), do: GenServer.call(server, :token, 30_000)

  @doc """
  Invalidate the cached token so the next `token/1` re-authenticates.

    * `invalidate(token)` — **compare-and-invalidate**: clears only if the cache
      still holds THIS token, so a stale rejection (e.g. a 401 for a token a
      concurrent login already replaced) can't wipe a good token and trigger a
      needless re-login that invalidates everyone again. This is what callers use
      on an auth error.
    * `invalidate()` — unconditional clear, for manual/test reset.
  """
  @spec invalidate(String.t() | :any, GenServer.server()) :: :ok
  def invalidate(token \\ :any, server \\ __MODULE__),
    do: GenServer.cast(server, {:invalidate, token})

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %State{}}

  @impl true
  def handle_call(:token, from, %State{} = state) do
    cond do
      fresh?(state) ->
        {:reply, {:ok, state.token}, state}

      # A login is already running — park this caller on it (the barrier).
      state.logging_in? ->
        {:noreply, %State{state | waiters: [from | state.waiters]}}

      # In the post-failure cooldown — fail fast without starting a new barrier.
      backing_off?(state) ->
        {:reply, {:error, :auth_unavailable}, state}

      # First caller to notice a stale token: kick off the one login.
      true ->
        {:noreply, start_login(%State{state | waiters: [from | state.waiters]})}
    end
  end

  @impl true
  def handle_cast({:invalidate, :any}, %State{} = state) do
    # Unconditional clear (manual / test reset). A login already in flight will
    # still cache its result when it returns.
    {:noreply, %State{state | token: nil, fetched_at_ms: nil}}
  end

  def handle_cast({:invalidate, token}, %State{} = state) do
    if state.token == token and not state.logging_in? do
      {:noreply, %State{state | token: nil, fetched_at_ms: nil}}
    else
      # Stale rejection (token already replaced) or a login is already minting a
      # fresh one — ignore, so we don't drop a good token or double-login.
      {:noreply, state}
    end
  end

  @impl true
  # Login task reported back. Success → reply everyone parked on the barrier and
  # cache. Replying to a since-timed-out caller is a harmless no-op.
  def handle_info({:login_result, {:ok, token}}, %State{} = state) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, token}))
    {:noreply, %State{token: token, fetched_at_ms: now_ms()}}
  end

  # Failure → keep the queued callers parked and retry after a backoff (up to
  # @max_attempts) so a transient FreightWare wobble resolves transparently
  # instead of failing the whole queue on the first error.
  def handle_info({:login_result, {:error, reason}}, %State{} = state) do
    if state.attempts < @max_attempts do
      Logger.warning(
        "Dovetail login attempt #{state.attempts}/#{@max_attempts} failed: #{inspect(reason)}"
      )

      Process.send_after(self(), :retry_login, retry_backoff_ms())
      {:noreply, state}
    else
      Logger.error("Dovetail login failed after #{@max_attempts} attempts: #{inspect(reason)}")
      Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))
      {:noreply, %State{failed_at_ms: now_ms()}}
    end
  end

  # Retry the login while the barrier is engaged; waiters stay queued throughout.
  def handle_info(:retry_login, %State{logging_in?: true} = state) do
    {:noreply, spawn_login(%State{state | attempts: state.attempts + 1})}
  end

  def handle_info(:retry_login, %State{} = state), do: {:noreply, state}

  # Ignore any late/unknown message so a stray signal can't crash the store.
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Engage the barrier (logging_in?) and run the first login attempt. Subsequent
  # retries reuse spawn_login/1 while the barrier stays up.
  defp start_login(%State{} = state) do
    spawn_login(%State{state | logging_in?: true, attempts: 1, failed_at_ms: nil})
  end

  # Run a login in a throwaway task that reports back via {:login_result, _}.
  defp spawn_login(%State{} = state) do
    parent = self()
    spawn(fn -> send(parent, {:login_result, safe_login()}) end)
    state
  end

  # Guarantee a result message even if login raises/exits, so the barrier can
  # never get stuck with logging_in? = true and waiters parked forever.
  defp safe_login do
    TragarAi.Dovetail.Client.login()
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp fresh?(%State{token: nil}), do: false

  defp fresh?(%State{fetched_at_ms: fetched_at}) when is_integer(fetched_at),
    do: now_ms() - fetched_at < @ttl_ms

  defp fresh?(_), do: false

  # True during the cooldown window after the barrier gave up on repeated failures.
  defp backing_off?(%State{failed_at_ms: nil}), do: false
  defp backing_off?(%State{failed_at_ms: t}), do: now_ms() - t < cooldown_ms()

  defp now_ms, do: System.monotonic_time(:millisecond)
end
