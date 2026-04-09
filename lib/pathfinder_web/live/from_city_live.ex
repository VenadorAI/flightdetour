defmodule PathfinderWeb.FromCityLive do
  @moduledoc """
  Hub page for all routes departing from a given city.
  URL: /from/:city_slug  e.g. /from/london

  Lists all covered destinations with their best current route status.
  Each destination links to the canonical pair page (/route/london-to-singapore).
  """
  use PathfinderWeb, :live_view
  alias Pathfinder.Routes

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"city_slug" => city_slug}, _uri, socket) do
    case Routes.get_city_by_slug(city_slug) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      city ->
        destinations = Routes.destinations_from_city(city.id)
        arrivals = if destinations == [], do: Routes.origins_to_city(city.id), else: []
        base = PathfinderWeb.Endpoint.url()

        dest_count = length(destinations)
        flowing_count = Enum.count(destinations, fn {_, best} -> best.score && best.score.label == :flowing end)

        description =
          if destinations == [] do
            "#{city.name} doesn't have covered outbound routes on FlightDetour yet. Check routes arriving in #{city.name}."
          else
            "#{dest_count} covered #{if dest_count == 1, do: "destination", else: "destinations"} from #{city.name} — disruption status, airspace exposure, and advisory scoring for each route. #{flowing_count} #{if flowing_count == 1, do: "route", else: "routes"} currently Flowing."
          end

        structured_data =
          Jason.encode!(%{
            "@context" => "https://schema.org",
            "@type" => "BreadcrumbList",
            "itemListElement" => [
              %{"@type" => "ListItem", "position" => 1, "name" => "FlightDetour", "item" => "#{base}/"},
              %{
                "@type" => "ListItem",
                "position" => 2,
                "name" => "From #{city.name}",
                "item" => "#{base}/from/#{city_slug}"
              }
            ]
          })

        socket =
          socket
          |> assign(:page_title, "Flights from #{city.name}: Airspace Risk by Route · FlightDetour")
          |> assign(:page_description, description)
          |> assign(:page_canonical, "#{base}/from/#{city_slug}")
          |> assign(:structured_data, structured_data)
          |> assign(:city, city)
          |> assign(:destinations, destinations)
          |> assign(:arrivals, arrivals)

        {:noreply, socket}
    end
  end
end
