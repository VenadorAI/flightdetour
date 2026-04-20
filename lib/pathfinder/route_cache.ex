defmodule Pathfinder.RouteCache do
  @moduledoc """
  ETS-backed in-process cache for stable route query results.

  Route data only changes when seeds are re-run or an operator updates scores.
  Caching the most frequent queries eliminates repeated DB round-trips on every
  LiveView mount, which is the dominant source of latency at current scale.

  Key TTLs:
    - Route pair results (find_routes): 10 minutes — safe because scores only
      change via deliberate operator action, not background processes.
    - City pair lists (active_city_pairs, featured_route_pairs): 5 minutes —
      shorter because these are used for search suggestions and sitemap logic.
    - City hub pages (destinations_from_city, origins_to_city): 5 minutes.

  To invalidate after a seed run or score update, call RouteCache.clear() from
  a Mix task or the admin interface.
  """

  use GenServer

  @table :route_cache
  @cleanup_interval_ms :timer.minutes(15)

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Fetch a cached value by key, or compute and cache it with the given TTL (seconds).

      RouteCache.fetch({:find_routes, origin_id, dest_id}, 600, fn ->
        expensive_db_query()
      end)
  """
  def fetch(key, ttl_seconds, fun) do
    case lookup(key) do
      {:ok, value} -> value
      :miss -> store(key, fun.(), ttl_seconds)
    end
  end

  @doc "Remove a single cached entry."
  def invalidate(key), do: :ets.delete(@table, key)

  @doc "Remove all cached entries. Call after reseeding or score updates."
  def clear, do: :ets.delete_all_objects(@table)

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    # Delete all entries whose expires_at timestamp is in the past
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.system_time(:second) < expires_at, do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  end

  defp store(key, value, ttl_seconds) do
    expires_at = System.system_time(:second) + ttl_seconds
    :ets.insert(@table, {key, value, expires_at})
    value
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
