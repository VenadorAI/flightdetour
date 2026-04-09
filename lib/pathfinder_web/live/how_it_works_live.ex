defmodule PathfinderWeb.HowItWorksLive do
  use PathfinderWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    base = PathfinderWeb.Endpoint.url()

    structured_data =
      Jason.encode!(%{
        "@context" => "https://schema.org",
        "@type" => "Article",
        "headline" => "How FlightDetour Works",
        "description" => "How FlightDetour scores flight corridors, monitors advisory zones, and measures freshness.",
        "url" => "#{base}/how-it-works",
        "publisher" => %{
          "@type" => "Organization",
          "name" => "FlightDetour",
          "url" => "#{base}/"
        }
      })

    {:ok,
     socket
     |> assign(:page_title, "How FlightDetour Works · Flight Routing Intelligence")
     |> assign(
       :page_description,
       "How FlightDetour scores flight corridors, monitors advisory zones, and measures freshness. A plain-language explanation of what the scores mean and what they don't."
     )
     |> assign(:page_canonical, "#{base}/how-it-works")
     |> assign(:structured_data, structured_data)}
  end
end
