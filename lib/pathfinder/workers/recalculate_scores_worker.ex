defmodule Pathfinder.Workers.RecalculateScoresWorker do
  @moduledoc """
  Recalculates route scores after disruption zone updates.
  Enqueue with: Pathfinder.Workers.RecalculateScoresWorker.enqueue()
  """
  use Oban.Worker, queue: :disruption, max_attempts: 3

  import Ecto.Query
  alias Pathfinder.Repo
  alias Pathfinder.Routes.{Route, RouteScore}
  alias Pathfinder.Scoring

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    route_ids = Map.get(args, "route_ids", :all)
    recalculate(route_ids)
    :ok
  end

  def enqueue(route_ids \\ :all) do
    args = if route_ids == :all, do: %{}, else: %{route_ids: route_ids}
    %{args: args} |> new() |> Oban.insert()
  end

  defp recalculate(:all) do
    Route
    |> where([r], r.is_active == true)
    |> Repo.all()
    |> Enum.each(&recalculate_route/1)
  end

  defp recalculate(route_ids) when is_list(route_ids) do
    Route
    |> where([r], r.id in ^route_ids)
    |> Repo.all()
    |> Enum.each(&recalculate_route/1)
  end

  defp recalculate_route(route) do
    route = Repo.preload(route, :score)
    existing = route.score || %RouteScore{}

    # In V1, scores are set manually in seeds/admin.
    # This worker recalculates the composite from stored dimension scores.
    if existing.id do
      %{composite_score: new_composite, label: new_label} =
        Scoring.calculate(
          existing.airspace_score,
          existing.corridor_score,
          existing.hub_score,
          existing.complexity_score,
          existing.operational_score
        )

      existing
      |> RouteScore.changeset(%{
        composite_score: new_composite,
        label: new_label,
        calculated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()
    end
  end
end
