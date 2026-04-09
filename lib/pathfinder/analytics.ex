defmodule Pathfinder.Analytics do
  @moduledoc """
  Structured event logging and DB persistence for key user interactions.

  High-value events (search_submitted, outbound_clicked) are persisted to the
  search_events table and queryable from the admin review page.

  All events are also written to Logger so log-drain sinks still work.
  """
  require Logger
  import Ecto.Query
  alias Pathfinder.Repo
  alias Pathfinder.Analytics.SearchEvent

  # Events persisted to the database for admin querying
  @persisted_events ~w(search_submitted outbound_clicked pair_page_loaded uncovered_search)

  @doc """
  Log a structured analytics event. Persists high-value events to DB.
  """
  def track(event, params \\ %{}) do
    Logger.info("[event] #{event} #{inspect(params)}")

    if event in @persisted_events do
      %SearchEvent{}
      |> SearchEvent.changeset(%{
        event_name: event,
        origin: to_string(params[:origin] || params["origin"] || ""),
        destination: to_string(params[:destination] || params["destination"] || ""),
        pair_slug: to_string(params[:pair_slug] || params["pair_slug"] || ""),
        metadata: Map.drop(params, [:origin, :destination, :pair_slug, "origin", "destination", "pair_slug"])
      })
      |> Repo.insert(returning: false, on_conflict: :nothing)
    end

    :ok
  end

  # ── Admin query helpers ───────────────────────────────────────────────────────

  @doc """
  Top searched city pairs, ranked by count, over the last N days.
  Returns [{origin, destination, count}].
  """
  def top_searched_pairs(days \\ 30, limit \\ 20) do
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Repo.all(
      from e in SearchEvent,
        where: e.event_name == "search_submitted",
        where: e.inserted_at >= ^since,
        where: e.origin != "" and e.destination != "",
        group_by: [e.origin, e.destination],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {e.origin, e.destination, count(e.id)}
    )
  end

  @doc """
  Top searched pairs that have NO active route coverage.
  These are the highest-priority expansion candidates.
  Returns [{origin, destination, count}].
  """
  def top_uncovered_searches(active_pairs, days \\ 30, limit \\ 15) do
    active_set = MapSet.new(active_pairs)

    top_searched_pairs(days, 100)
    |> Enum.reject(fn {o, d, _} -> MapSet.member?(active_set, {o, d}) end)
    |> Enum.take(limit)
  end

  @doc """
  Top searched origins, ranked by distinct pair count.
  """
  def top_origins(days \\ 30, limit \\ 10) do
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Repo.all(
      from e in SearchEvent,
        where: e.event_name == "search_submitted",
        where: e.inserted_at >= ^since,
        where: e.origin != "",
        group_by: e.origin,
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {e.origin, count(e.id)}
    )
  end

  @doc """
  Top searched destinations, ranked by count.
  """
  def top_destinations(days \\ 30, limit \\ 10) do
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Repo.all(
      from e in SearchEvent,
        where: e.event_name == "search_submitted",
        where: e.inserted_at >= ^since,
        where: e.destination != "",
        group_by: e.destination,
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {e.destination, count(e.id)}
    )
  end

  @doc """
  Routes searched directly (landing on the not-covered page), ranked by count.
  These are raw demand signals — pairs that users want but we don't have.
  Returns [{origin, destination, count}].
  """
  def direct_uncovered_searches(days \\ 30, limit \\ 20) do
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Repo.all(
      from e in SearchEvent,
        where: e.event_name == "uncovered_search",
        where: e.inserted_at >= ^since,
        where: e.origin != "" and e.destination != "",
        group_by: [e.origin, e.destination],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {e.origin, e.destination, count(e.id)}
    )
  end

  @doc """
  Merged expansion priority: combines direct gap searches (not-covered page hits)
  with inferred uncovered searches (submitted pairs with no routes), deduplicates,
  and ranks by total combined signal.

  Returns [{origin, destination, direct_count, inferred_count, total}] sorted by total desc.
  """
  def expansion_priority(active_pairs, days \\ 30, limit \\ 20) do
    direct = direct_uncovered_searches(days, 100) |> Map.new(fn {o, d, n} -> {{o, d}, n} end)
    inferred = top_uncovered_searches(active_pairs, days, 100) |> Map.new(fn {o, d, n} -> {{o, d}, n} end)

    all_pairs = Map.keys(direct) ++ Map.keys(inferred) |> Enum.uniq()

    all_pairs
    |> Enum.map(fn {o, d} = pair ->
      dc = Map.get(direct, pair, 0)
      ic = Map.get(inferred, pair, 0)
      # Direct hits weighted 2× — user explicitly landed on not-covered page
      {o, d, dc, ic, dc * 2 + ic}
    end)
    |> Enum.sort_by(fn {_, _, _, _, total} -> -total end)
    |> Enum.take(limit)
  end

  @doc "Total search count for the last N days."
  def search_count(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Repo.one(
      from e in SearchEvent,
        where: e.event_name == "search_submitted",
        where: e.inserted_at >= ^since,
        select: count(e.id)
    ) || 0
  end
end
