defmodule PathfinderWeb.Router do
  use PathfinderWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PathfinderWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :admin_auth do
    plug :require_admin_auth
  end

  scope "/", PathfinderWeb do
    pipe_through :browser

    live "/", SearchLive, :index

    # Canonical SEO pair pages — primary indexable surface
    live "/route/:pair_slug", ResultsLive, :pair

    # Legacy query-param URL — redirects to canonical slug URL
    live "/routes", ResultsLive, :index

    # Route detail pages (numeric ID, linked from pair pages)
    live "/routes/:id", RouteDetailLive, :show

    # From-city and to-city hub pages
    live "/from/:city_slug", FromCityLive, :index
    live "/to/:city_slug", ToCityLive, :index

    live "/disruption/:slug", DisruptionZoneLive, :show

    # Trust / methodology page
    live "/how-it-works", HowItWorksLive, :index

    # Intent-driven guide pages
    live "/guide/do-flights-still-fly-over-iran", GuideIranAirspaceLive, :index
    live "/guide/why-flights-to-asia-are-longer", GuideFlightsLongerLive, :index
    live "/guide/london-to-bangkok-route-comparison", GuideLondonBangkokLive, :index
    live "/guide/istanbul-vs-dubai", GuideIstanbulDubaiLive, :index

    # Outbound click tracker — logs provider + pair before redirecting
    get "/go", GoController, :redirect_outbound

    get "/sitemap.xml", SitemapController, :index
    get "/robots.txt", RobotsController, :index
  end

  # Health check — no auth, no CSRF, bypasses browser pipeline
  scope "/", PathfinderWeb do
    pipe_through :api
    get "/health", HealthController, :index
  end

  # Internal admin — protected by basic auth in production via ADMIN_PASS env var.
  scope "/admin", PathfinderWeb do
    pipe_through [:browser, :admin_auth]

    live "/review", AdminReviewLive, :index
  end

  # ── Admin basic auth ────────────────────────────────────────────────────────
  # In dev (no ADMIN_PASS): passes through.
  # In prod with ADMIN_PASS set: requires HTTP Basic credentials.
  # In prod with no ADMIN_PASS: blocks with 401 (fail-safe).

  defp require_admin_auth(conn, _opts) do
    case {Application.get_env(:pathfinder, :env), System.get_env("ADMIN_PASS")} do
      {:dev, _} ->
        conn

      {_, nil} ->
        conn
        |> Plug.BasicAuth.request_basic_auth()
        |> halt()

      {_, password} ->
        username = System.get_env("ADMIN_USER", "admin")
        Plug.BasicAuth.basic_auth(conn, username: username, password: password)
    end
  end
end
