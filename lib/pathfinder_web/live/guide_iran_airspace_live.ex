defmodule PathfinderWeb.GuideIranAirspaceLive do
  use PathfinderWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    base = PathfinderWeb.Endpoint.url()

    structured_data =
      Jason.encode!(%{
        "@context" => "https://schema.org",
        "@type" => "Article",
        "headline" => "Do Flights Still Fly Over Iran?",
        "description" => "Most Western airlines no longer route through Iranian airspace. Here's what changed, which corridors they use instead, and how to compare your specific route options.",
        "url" => "#{base}/guide/do-flights-still-fly-over-iran",
        "publisher" => %{
          "@type" => "Organization",
          "name" => "FlightDetour",
          "url" => "#{base}/"
        }
      })

    {:ok,
     socket
     |> assign(:page_title, "Do Flights Still Fly Over Iran? · FlightDetour")
     |> assign(
       :page_description,
       "Most Western airlines no longer route through Iranian airspace. Here's what changed, which corridors they use instead, and how to compare your specific route options."
     )
     |> assign(:page_canonical, "#{base}/guide/do-flights-still-fly-over-iran")
     |> assign(:structured_data, structured_data)}
  end
end
