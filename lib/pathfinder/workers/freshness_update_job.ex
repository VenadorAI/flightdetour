defmodule Pathfinder.Workers.FreshnessUpdateJob do
  @moduledoc """
  Oban job: recompute age-based freshness for all active route scores.

  Scheduled daily. Does not override "review_required" — that state is set by
  AdvisoryCheckJob when a source page changes and cleared only by an admin
  marking the route as reviewed.

  Logic per route:
    - If freshness_state is already "review_required" → skip (preserve it)
    - Else compute from last_reviewed_at:
        > 30 days → "stale"
        > 7 days  → "aging"
        else       → "current"
  """
  use Oban.Worker, queue: :disruption, max_attempts: 3

  require Logger
  import Ecto.Query

  alias Pathfinder.Repo
  alias Pathfinder.Routes.{Route, RouteScore}

  @current_days 7
  @stale_days 30

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[FreshnessUpdateJob] Recomputing age-based freshness")

    routes =
      Repo.all(
        from r in Route,
          where: r.is_active == true,
          join: s in RouteScore,
          on: s.route_id == r.id,
          where: s.freshness_state != "review_required",
          select: %{route_id: r.id, reviewed_at: r.last_reviewed_at, score_id: s.id}
      )

    {stale, aging, current} =
      Enum.reduce(routes, {[], [], []}, fn row, {s, a, c} ->
        case age_state(row.reviewed_at) do
          :stale -> {[row.score_id | s], a, c}
          :aging -> {s, [row.score_id | a], c}
          :current -> {s, a, [row.score_id | c]}
        end
      end)

    if length(stale) > 0 do
      Repo.update_all(from(s in RouteScore, where: s.id in ^stale), set: [freshness_state: "stale"])
    end

    if length(aging) > 0 do
      Repo.update_all(from(s in RouteScore, where: s.id in ^aging), set: [freshness_state: "aging"])
    end

    if length(current) > 0 do
      Repo.update_all(from(s in RouteScore, where: s.id in ^current), set: [freshness_state: "current"])
    end

    Logger.info("[FreshnessUpdateJob] Done — stale: #{length(stale)}, aging: #{length(aging)}, current: #{length(current)}")
    :ok
  end

  def enqueue do
    %{} |> new() |> Oban.insert()
  end

  defp age_state(nil), do: :stale
  defp age_state(reviewed_at) do
    days = DateTime.diff(DateTime.utc_now(), reviewed_at, :day)
    cond do
      days > @stale_days -> :stale
      days > @current_days -> :aging
      true -> :current
    end
  end
end
