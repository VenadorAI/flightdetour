defmodule PathfinderWeb.ToCityLive do
  @moduledoc """
  Hub page for all routes arriving at a given city.
  URL: /to/:city_slug  e.g. /to/singapore

  Lists all covered origins with their best current route status.
  Each origin links to the canonical pair page (/route/london-to-singapore).
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
        origins = Routes.origins_to_city(city.id)
        departures = if origins == [], do: Routes.destinations_from_city(city.id), else: []
        base = PathfinderWeb.Endpoint.url()

        origin_count = length(origins)
        flowing_count = Enum.count(origins, fn {_, best} -> best.score && best.score.label == :flowing end)

        description =
          if origins == [] do
            "#{city.name} isn't covered as a destination yet on FlightDetour. Check routes departing from #{city.name}."
          else
            "#{origin_count} covered #{if origin_count == 1, do: "origin", else: "origins"} with flights to #{city.name} — disruption status, airspace exposure, and advisory scoring for each inbound corridor. #{flowing_count} #{if flowing_count == 1, do: "route", else: "routes"} currently Flowing."
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
                "name" => "Flights to #{city.name}",
                "item" => "#{base}/to/#{city_slug}"
              }
            ]
          })

        socket =
          socket
          |> assign(:page_title, "Flights to #{city.name}: Airspace Risk by Route · FlightDetour")
          |> assign(:page_description, description)
          |> assign(:page_canonical, "#{base}/to/#{city_slug}")
          |> assign(:structured_data, structured_data)
          |> assign(:city, city)
          |> assign(:origins, origins)
          |> assign(:departures, departures)

        {:noreply, socket}
    end
  end
end
