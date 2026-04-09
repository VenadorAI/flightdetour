defmodule PathfinderWeb.AdminReviewLive do
  @moduledoc """
  Internal review dashboard — protected by ADMIN_PASS basic auth in production.

  Shows:
  - Disruption zones sorted by most-recently-changed, with affected route count
  - Inline edit for zone status / severity / summary_text
  - Routes needing review (review_required, stale) and aging routes
  - One-click "Mark as reviewed" + "Rescore" per route
  - Manual trigger for the advisory source check
  """
  use PathfinderWeb, :live_view
  import Ecto.Query

  alias Pathfinder.Repo
  alias Pathfinder.Advisory.Freshness
  alias Pathfinder.Analytics
  alias Pathfinder.Disruption.DisruptionZone
  alias Pathfinder.Routes.{Route, RouteDisruptionFactor, RouteScore}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Advisory Review · FlightDetour Admin")
     |> assign(:page_noindex, true)
     |> assign(:check_running, false)
     |> assign(:last_check_result, nil)
     |> assign(:editing_zone_id, nil)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("run-check", _params, socket) do
    socket = assign(socket, :check_running, true)

    case Pathfinder.Workers.AdvisoryCheckJob.enqueue() do
      {:ok, _job} ->
        {:noreply, assign(socket, :last_check_result, "Advisory check queued — results will appear after the job runs.")}

      {:error, reason} ->
        {:noreply, assign(socket, :last_check_result, "Failed to enqueue: #{inspect(reason)}")}
    end
  end

  def handle_event("run-freshness-job", _params, socket) do
    case Pathfinder.Workers.FreshnessUpdateJob.enqueue() do
      {:ok, _} ->
        {:noreply, assign(socket, :last_check_result, "Freshness update queued — scores will update momentarily.") |> load_data()}

      {:error, reason} ->
        {:noreply, assign(socket, :last_check_result, "Failed to enqueue: #{inspect(reason)}")}
    end
  end

  # Force a single route score to a specific freshness state.
  # Used for dev/QA — lets you verify UI behaviour without waiting for routes to age.
  def handle_event("force-freshness", %{"route-id" => id, "state" => state}, socket)
      when state in ["current", "aging", "stale", "review_required"] do
    route_id = String.to_integer(id)

    Repo.update_all(
      from(s in RouteScore, where: s.route_id == ^route_id),
      set: [freshness_state: state]
    )

    {:noreply, socket |> assign(:last_check_result, "Route #{route_id} freshness forced to #{state}.") |> load_data()}
  end

  def handle_event("force-freshness", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("mark-reviewed", %{"route-id" => id}, socket) do
    route_id = String.to_integer(id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      Repo.update_all(
        from(r in Route, where: r.id == ^route_id),
        set: [last_reviewed_at: now]
      )

      Repo.update_all(
        from(s in RouteScore, where: s.route_id == ^route_id),
        set: [freshness_state: "current"]
      )
    end)

    Pathfinder.Workers.RecalculateScoresWorker.enqueue([route_id])

    {:noreply, load_data(socket)}
  end

  def handle_event("rescore-route", %{"route-id" => id}, socket) do
    route_id = String.to_integer(id)
    Pathfinder.Workers.RecalculateScoresWorker.enqueue([route_id])
    {:noreply, assign(socket, :last_check_result, "Rescore queued for route #{route_id}.")}
  end

  def handle_event("mark-zone-current", %{"zone-id" => id}, socket) do
    zone_id = String.to_integer(id)

    Repo.update_all(
      from(z in DisruptionZone, where: z.id == ^zone_id),
      set: [review_status: "current"]
    )

    {:noreply, load_data(socket)}
  end

  def handle_event("start-edit-zone", %{"zone-id" => id}, socket) do
    {:noreply, assign(socket, :editing_zone_id, String.to_integer(id))}
  end

  def handle_event("cancel-edit-zone", _params, socket) do
    {:noreply, assign(socket, :editing_zone_id, nil)}
  end

  def handle_event("save-zone", params, socket) do
    zone_id = String.to_integer(params["zone_id"])
    zone = Repo.get!(DisruptionZone, zone_id)

    attrs = %{
      status: params["status"],
      severity: params["severity"],
      summary_text: params["summary_text"]
    }

    case zone |> DisruptionZone.changeset(attrs) |> Repo.update() do
      {:ok, _} ->
        socket =
          socket
          |> assign(:editing_zone_id, nil)
          |> assign(:last_check_result, "Zone updated.")
          |> load_data()

        {:noreply, socket}

      {:error, changeset} ->
        errors = Enum.map_join(changeset.errors, ", ", fn {k, {msg, _}} -> "#{k}: #{msg}" end)
        {:noreply, assign(socket, :last_check_result, "Save failed — #{errors}")}
    end
  end

  # --- Private ---

  defp load_data(socket) do
    {zones, zone_route_counts} = load_zones_with_counts()
    routes_needing_review = load_routes_by_freshness(["review_required", "stale"])
    aging_routes = load_routes_by_freshness(["aging"])
    health = load_health_summary(zones)
    changed_zones_by_route = load_changed_zones_for_routes(routes_needing_review)
    analytics = load_analytics()
    dev_routes = load_dev_routes()

    socket
    |> assign(:zones, zones)
    |> assign(:zone_route_counts, zone_route_counts)
    |> assign(:routes_needing_review, routes_needing_review)
    |> assign(:aging_routes, aging_routes)
    |> assign(:health, health)
    |> assign(:changed_zones_by_route, changed_zones_by_route)
    |> assign(:analytics, analytics)
    |> assign(:dev_routes, dev_routes)
    |> assign(:check_running, false)
  end

  # Loads up to 20 active routes for the dev-tools freshness panel.
  # Prioritises non-current routes so reviewable items surface first,
  # then fills with current routes to guarantee the table is never empty.
  defp load_dev_routes do
    non_current = load_routes_by_freshness(["review_required", "stale", "aging"])

    if length(non_current) >= 20 do
      Enum.take(non_current, 20)
    else
      current = load_routes_by_freshness(["current"]) |> Enum.take(20 - length(non_current))
      non_current ++ current
    end
  end

  defp load_analytics do
    active_pairs = Pathfinder.Routes.active_city_pairs()
    %{
      search_count_30d: Analytics.search_count(30),
      top_pairs: Analytics.top_searched_pairs(30, 15),
      uncovered_searches: Analytics.top_uncovered_searches(active_pairs, 30, 10),
      direct_uncovered: Analytics.direct_uncovered_searches(30, 15),
      expansion_priority: Analytics.expansion_priority(active_pairs, 30, 15),
      top_origins: Analytics.top_origins(30, 8),
      top_destinations: Analytics.top_destinations(30, 8)
    }
  end

  # Returns {zones, %{zone_id => active_route_count}}.
  # Zones sorted by last_changed_at desc so recently updated sources surface first.
  defp load_zones_with_counts do
    zones =
      Repo.all(
        from z in DisruptionZone,
          order_by: [desc_nulls_last: z.last_changed_at, asc: z.name]
      )

    route_counts =
      Repo.all(
        from rf in RouteDisruptionFactor,
          join: r in Route, on: r.id == rf.route_id,
          where: r.is_active == true,
          group_by: rf.disruption_zone_id,
          select: {rf.disruption_zone_id, count(rf.id)}
      )
      |> Map.new()

    {zones, route_counts}
  end

  defp load_routes_by_freshness(states) do
    Repo.all(
      from r in Route,
        join: s in RouteScore,
        on: s.route_id == r.id,
        where: s.freshness_state in ^states,
        join: oc in assoc(r, :origin_city),
        join: dc in assoc(r, :destination_city),
        preload: [origin_city: oc, destination_city: dc, score: s],
        order_by: [desc: s.freshness_state, asc: r.last_reviewed_at]
    )
  end

  defp freshness_badge_class("review_required"), do: "bg-red-400/10 border-red-400/25 text-red-400/80"
  defp freshness_badge_class("stale"), do: "bg-orange-400/10 border-orange-400/25 text-orange-400/80"
  defp freshness_badge_class("aging"), do: "bg-amber-400/10 border-amber-400/20 text-amber-400/70"
  defp freshness_badge_class(_), do: "bg-emerald-400/10 border-emerald-400/20 text-emerald-400/70"

  defp freshness_label("review_required"), do: "Needs review"
  defp freshness_label("stale"), do: "Stale"
  defp freshness_label("aging"), do: "Aging"
  defp freshness_label(_), do: "Current"

  defp zone_status_class("review_required"), do: "text-red-400/80"
  defp zone_status_class(_), do: "text-emerald-400/60"

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Freshness.format_age(dt) || Calendar.strftime(dt, "%b %d %H:%M UTC")

  defp format_date(nil), do: "—"
  defp format_date(dt), do: Calendar.strftime(dt, "%b %d, %Y")

  # --- Health summary ---

  # Aggregates freshness state counts and source check health across all active routes.
  defp load_health_summary(zones) do
    freshness_counts =
      Repo.all(
        from s in RouteScore,
          join: r in Route, on: r.id == s.route_id,
          where: r.is_active == true,
          group_by: s.freshness_state,
          select: {s.freshness_state, count(s.id)}
      )
      |> Map.new()

    monitored_zones = Enum.filter(zones, & &1.source_url)
    last_check =
      monitored_zones
      |> Enum.map(& &1.last_checked_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    stale_check_threshold_hours = 8
    stale_source_count =
      Enum.count(monitored_zones, fn z ->
        is_nil(z.last_checked_at) ||
          DateTime.diff(DateTime.utc_now(), z.last_checked_at, :second) > stale_check_threshold_hours * 3600
      end)

    critically_failing_sources =
      Enum.count(monitored_zones, fn z -> (z.consecutive_check_failures || 0) >= 3 end)

    %{
      freshness_counts: freshness_counts,
      total_routes: Enum.sum(Map.values(freshness_counts)),
      last_source_check: last_check,
      monitored_zone_count: length(monitored_zones),
      stale_source_count: stale_source_count,
      critically_failing_sources: critically_failing_sources,
      checker_healthy: stale_source_count == 0 && not is_nil(last_check) && critically_failing_sources == 0
    }
  end

  # For each route in the review queue, find which zones changed after the route was last reviewed.
  # This tells the admin exactly WHY the route is flagged.
  defp load_changed_zones_for_routes([]), do: %{}

  defp load_changed_zones_for_routes(routes) do
    route_ids = Enum.map(routes, & &1.id)

    Repo.all(
      from f in RouteDisruptionFactor,
        join: z in DisruptionZone, on: z.id == f.disruption_zone_id,
        join: r in Route, on: r.id == f.route_id,
        where: f.route_id in ^route_ids,
        where: not is_nil(z.last_changed_at),
        where: is_nil(r.last_reviewed_at) or z.last_changed_at > r.last_reviewed_at,
        select: %{route_id: f.route_id, zone_name: z.name, zone_slug: z.slug}
    )
    |> Enum.group_by(& &1.route_id, & &1)
  end
end
