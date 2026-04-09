defmodule Mix.Tasks.Pathfinder.Dev.Freshness do
  @moduledoc """
  Sets representative routes to each freshness state for UI testing.

  Picks the first N active routes and distributes them across:
    current, aging, stale, review_required

  Usage:
    mix pathfinder.dev.freshness

  After running, visit /admin/review to see and interact with the force-freshness
  controls in the Dev Tools · Freshness Testing section.

  To reset all routes back to current, run the freshness job from the admin nav
  or run: mix pathfinder.dev.freshness --reset
  """
  use Mix.Task

  @shortdoc "Seed representative freshness states across dev routes for UI testing"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    import Ecto.Query
    alias Pathfinder.Repo
    alias Pathfinder.Routes.{Route, RouteScore}

    reset? = "--reset" in args

    routes =
      Repo.all(
        from r in Route,
          join: s in RouteScore, on: s.route_id == r.id,
          join: oc in assoc(r, :origin_city),
          join: dc in assoc(r, :destination_city),
          where: r.is_active == true,
          preload: [origin_city: oc, destination_city: dc, score: s],
          order_by: r.id,
          limit: 20
      )

    if Enum.empty?(routes) do
      Mix.shell().error("No active routes found. Run: mix run priv/repo/seeds.exs")
      exit({:shutdown, 1})
    end

    if reset? do
      Repo.update_all(
        from(s in RouteScore,
          join: r in Route, on: r.id == s.route_id,
          where: r.is_active == true
        ),
        set: [freshness_state: "current"]
      )
      Mix.shell().info("Reset all route scores to :current.")
    else
      states = ["current", "aging", "stale", "review_required"]

      # Distribute routes round-robin across states so each state has multiple examples.
      routes
      |> Enum.with_index()
      |> Enum.each(fn {route, i} ->
        state = Enum.at(states, rem(i, length(states)))

        Repo.update_all(
          from(s in RouteScore, where: s.route_id == ^route.id),
          set: [freshness_state: state]
        )

        origin = route.origin_city.name
        dest = route.destination_city.name
        Mix.shell().info("  [#{state}] #{origin} → #{dest} (#{route.route_name})")
      end)

      Mix.shell().info("""

      Done. #{length(routes)} routes set across #{length(states)} freshness states.
      Visit http://localhost:4000/admin/review → Dev Tools · Freshness Testing
      to see the force-freshness controls and verify each UI state.

      To reset: mix pathfinder.dev.freshness --reset
      """)
    end
  end
end
