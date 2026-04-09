defmodule PathfinderWeb.GuideFlightsLongerLive do
  use PathfinderWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    base = PathfinderWeb.Endpoint.url()

    structured_data =
      Jason.encode!(%{
        "@context" => "https://schema.org",
        "@type" => "Article",
        "headline" => "Why Flights to Asia Are Taking Longer",
        "description" => "Flights between Europe and Asia now take 1–3 hours longer than before 2022. The cause is airspace rerouting — here's what changed and how it varies by corridor.",
        "url" => "#{base}/guide/why-flights-to-asia-are-longer",
        "publisher" => %{
          "@type" => "Organization",
          "name" => "FlightDetour",
          "url" => "#{base}/"
        }
      })

    {:ok,
     socket
     |> assign(:page_title, "Why Flights to Asia Are Taking Longer · FlightDetour")
     |> assign(
       :page_description,
       "Flights between Europe and Asia now take 1–3 hours longer than before 2022. The cause is airspace rerouting — here's what changed and how it varies by corridor."
     )
     |> assign(:page_canonical, "#{base}/guide/why-flights-to-asia-are-longer")
     |> assign(:structured_data, structured_data)}
  end
end
