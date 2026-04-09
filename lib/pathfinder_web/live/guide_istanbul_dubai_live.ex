defmodule PathfinderWeb.GuideIstanbulDubaiLive do
  use PathfinderWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    base = PathfinderWeb.Endpoint.url()

    structured_data =
      Jason.encode!(%{
        "@context" => "https://schema.org",
        "@type" => "Article",
        "headline" => "Via Istanbul vs Via Dubai: What the Difference Means Now",
        "description" => "Via Istanbul and via Dubai are the two most common one-stop routings from Europe to Asia. Since 2022 they have a meaningful structural difference: airspace exposure on the inbound leg.",
        "url" => "#{base}/guide/istanbul-vs-dubai",
        "publisher" => %{
          "@type" => "Organization",
          "name" => "FlightDetour",
          "url" => "#{base}/"
        }
      })

    {:ok,
     socket
     |> assign(:page_title, "Via Istanbul vs Via Dubai: What the Difference Means Now · FlightDetour")
     |> assign(
       :page_description,
       "Via Istanbul and via Dubai are the two most common one-stop routings from Europe to Asia. Since 2022 they have a meaningful structural difference: airspace exposure on the inbound leg."
     )
     |> assign(:page_canonical, "#{base}/guide/istanbul-vs-dubai")
     |> assign(:structured_data, structured_data)}
  end
end
