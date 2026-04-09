defmodule PathfinderWeb.GoController do
  @moduledoc """
  /go — server-side outbound redirect with click logging.

  Logs every outbound click as an analytics event before redirecting.
  This is the only way to get reliable server-side monetization signal,
  independent of ad-blockers or client-side JS state.

  Parameters:
    provider  — "google_flights" | "skyscanner"
    o         — IATA origin code (e.g. "LHR")
    d         — IATA destination code (e.g. "SIN")
    pair      — pair_slug (e.g. "london-to-singapore") — optional, for attribution
    route_id  — route ID — optional, for attribution

  The provider + IATA codes are used to build the destination URL via
  Pathfinder.Outbound, so affiliate params and UTM tracking are applied
  automatically from the Outbound module's logic.
  """
  use PathfinderWeb, :controller
  alias Pathfinder.{Analytics, Outbound}

  def redirect_outbound(conn, %{"provider" => provider, "o" => iata_o, "d" => iata_d} = params) do
    Analytics.track("outbound_clicked", %{
      provider: provider,
      iata_o: iata_o,
      iata_d: iata_d,
      pair_slug: params["pair"],
      route_id: params["route_id"]
    })

    provider_atom =
      case provider do
        "google_flights" -> :google_flights
        "skyscanner" -> :skyscanner
        _ -> nil
      end

    url = provider_atom && Outbound.url_for(provider_atom, iata_o, iata_d)

    redirect(conn, external: url || "/")
  end

  def redirect_outbound(conn, _params) do
    redirect(conn, to: "/")
  end
end
