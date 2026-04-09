defmodule PathfinderWeb.HealthController do
  @moduledoc """
  /health — returns 200 when app is running and DB is reachable, 503 otherwise.

  Used by:
  - Fly.io / Render health checks (prevents routing to unhealthy instances)
  - UptimeRobot / BetterUptime / external monitoring
  - Load balancer liveness probes

  Response format:
    200: {"status":"ok","db":"ok"}
    503: {"status":"error","db":"unavailable"}
  """
  use PathfinderWeb, :controller

  def index(conn, _params) do
    case db_ok?() do
      true ->
        conn
        |> put_status(200)
        |> json(%{status: "ok", db: "ok"})

      false ->
        conn
        |> put_status(503)
        |> json(%{status: "error", db: "unavailable"})
    end
  end

  defp db_ok? do
    case Ecto.Adapters.SQL.query(Pathfinder.Repo, "SELECT 1", [], timeout: 5_000) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
