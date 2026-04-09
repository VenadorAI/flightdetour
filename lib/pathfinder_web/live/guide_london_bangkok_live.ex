defmodule PathfinderWeb.GuideLondonBangkokLive do
  use PathfinderWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    base = PathfinderWeb.Endpoint.url()

    structured_data =
      Jason.encode!(%{
        "@context" => "https://schema.org",
        "@type" => "Article",
        "headline" => "London to Bangkok: Route Comparison",
        "description" => "London to Bangkok has three main routing corridors with meaningfully different airspace exposure and journey times. Here's what each option looks like right now.",
        "url" => "#{base}/guide/london-to-bangkok-route-comparison",
        "publisher" => %{
          "@type" => "Organization",
          "name" => "FlightDetour",
          "url" => "#{base}/"
        }
      })

    {:ok,
     socket
     |> assign(:page_title, "London to Bangkok: Route Comparison · FlightDetour")
     |> assign(
       :page_description,
       "London to Bangkok has three main routing corridors with meaningfully different airspace exposure and journey times. Here's what each option looks like right now."
     )
     |> assign(:page_canonical, "#{base}/guide/london-to-bangkok-route-comparison")
     |> assign(:structured_data, structured_data)}
  end
end
