defmodule PathfinderWeb.SearchLive do
  use PathfinderWeb, :live_view
  alias Pathfinder.{Routes, CitySlug, Analytics, Disruption}

  @impl true
  def mount(_params, _session, socket) do
    base = PathfinderWeb.Endpoint.url()

    structured_data =
      Jason.encode!(%{
        "@context" => "https://schema.org",
        "@type" => "WebSite",
        "name" => "FlightDetour",
        "description" => "Flight routing intelligence for long-haul travel. Compare corridors by airspace exposure before you book.",
        "url" => "#{base}/",
        "potentialAction" => %{
          "@type" => "SearchAction",
          "target" => %{
            "@type" => "EntryPoint",
            "urlTemplate" => "#{base}/route/{search_term_string}"
          },
          "query-input" => "required name=search_term_string"
        }
      })

    {:ok,
     socket
     |> assign(:page_title, "FlightDetour — Compare rerouted long-haul flights before you book")
     |> assign(:page_description, "Some flights to Asia and the Middle East are now longer, rerouted, or more exposed than others. See which route still looks cleaner before you book.")
     |> assign(:page_canonical, "#{base}/")
     |> assign(:structured_data, structured_data)
     |> assign(:origin, "")
     |> assign(:destination, "")
     |> assign(:origin_suggestions, [])
     |> assign(:destination_suggestions, [])
     |> assign(:origin_city, nil)
     |> assign(:destination_city, nil)
     |> assign(:featured_pairs, Routes.featured_route_pairs())
     |> assign(:route_count, Routes.active_route_count())
     |> assign(:active_zones, Disruption.list_active_zones())
     |> assign(:latest_source_check, Disruption.latest_source_check())}
  end

  # Pre-populate the search form when navigating back from results with ?from=X&to=Y
  @impl true
  def handle_params(%{"from" => from, "to" => to}, _uri, socket)
      when is_binary(from) and from != "" and is_binary(to) and to != "" do
    origin_city = Pathfinder.Routes.get_city_by_name(from)
    dest_city = Pathfinder.Routes.get_city_by_name(to)

    {:noreply,
     socket
     |> assign(:origin, from)
     |> assign(:destination, to)
     |> assign(:origin_city, origin_city)
     |> assign(:destination_city, dest_city)
     |> assign(:origin_suggestions, [])
     |> assign(:destination_suggestions, [])}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("origin-changed", %{"value" => value}, socket) do
    suggestions = if String.length(value) >= 2, do: Routes.search_cities(value), else: []

    {:noreply,
     socket
     |> assign(:origin, value)
     |> assign(:origin_city, nil)
     |> assign(:origin_suggestions, suggestions)}
  end

  def handle_event("destination-changed", %{"value" => value}, socket) do
    suggestions = if String.length(value) >= 2, do: Routes.search_cities(value), else: []

    {:noreply,
     socket
     |> assign(:destination, value)
     |> assign(:destination_city, nil)
     |> assign(:destination_suggestions, suggestions)}
  end

  def handle_event("select-origin", %{"id" => id, "name" => name}, socket) do
    city = Routes.get_city!(id)

    {:noreply,
     socket
     |> assign(:origin, name)
     |> assign(:origin_city, city)
     |> assign(:origin_suggestions, [])}
  end

  def handle_event("select-destination", %{"id" => id, "name" => name}, socket) do
    city = Routes.get_city!(id)

    {:noreply,
     socket
     |> assign(:destination, name)
     |> assign(:destination_city, city)
     |> assign(:destination_suggestions, [])}
  end

  def handle_event("select-popular", %{"origin" => origin, "destination" => destination}, socket) do
    origin_city = Routes.get_city_by_name(origin)
    destination_city = Routes.get_city_by_name(destination)

    socket =
      socket
      |> assign(:origin, origin)
      |> assign(:destination, destination)
      |> assign(:origin_city, origin_city)
      |> assign(:destination_city, destination_city)
      |> assign(:origin_suggestions, [])
      |> assign(:destination_suggestions, [])

    {:noreply, socket}
  end

  def handle_event("search", _params, socket) do
    case {socket.assigns.origin_city, socket.assigns.destination_city} do
      {nil, _} ->
        {:noreply, put_flash(socket, :error, "Please select a valid origin city.")}

      {_, nil} ->
        {:noreply, put_flash(socket, :error, "Please select a valid destination city.")}

      {origin, destination} ->
        Analytics.track("search_submitted", %{origin: origin.name, destination: destination.name})
        slug = CitySlug.pair_slug(origin.name, destination.name)
        {:noreply, push_navigate(socket, to: ~p"/route/#{slug}")}
    end
  end

  def handle_event("dismiss-suggestions", _params, socket) do
    {:noreply,
     socket
     |> assign(:origin_suggestions, [])
     |> assign(:destination_suggestions, [])}
  end

end
