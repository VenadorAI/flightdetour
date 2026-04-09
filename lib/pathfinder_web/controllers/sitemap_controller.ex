defmodule PathfinderWeb.SitemapController do
  use PathfinderWeb, :controller

  alias Pathfinder.{Routes, Disruption, CitySlug}

  def index(conn, _params) do
    city_pairs = Routes.active_city_pairs()
    origin_cities = Routes.active_origin_cities()
    dest_cities = Routes.active_destination_cities()
    zones = Disruption.list_active_zones()
    route_ids = Routes.list_active_routes_for_sitemap()
    base = PathfinderWeb.Endpoint.url()

    xml = build_sitemap(base, city_pairs, origin_cities, dest_cities, zones, route_ids)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  defp build_sitemap(base, city_pairs, origin_cities, dest_cities, zones, route_ids) do
    pair_urls =
      city_pairs
      |> Enum.map(fn {origin_name, dest_name} ->
        slug = CitySlug.pair_slug(origin_name, dest_name)
        """
          <url>
            <loc>#{base}/route/#{slug}</loc>
            <changefreq>daily</changefreq>
            <priority>0.9</priority>
          </url>
        """
      end)
      |> Enum.join()

    from_city_urls =
      origin_cities
      |> Enum.map(fn city ->
        """
          <url>
            <loc>#{base}/from/#{city.slug}</loc>
            <changefreq>weekly</changefreq>
            <priority>0.7</priority>
          </url>
        """
      end)
      |> Enum.join()

    to_city_urls =
      dest_cities
      |> Enum.map(fn city ->
        """
          <url>
            <loc>#{base}/to/#{city.slug}</loc>
            <changefreq>weekly</changefreq>
            <priority>0.7</priority>
          </url>
        """
      end)
      |> Enum.join()

    zone_urls =
      zones
      |> Enum.map(fn z ->
        """
          <url>
            <loc>#{base}/disruption/#{z.slug}</loc>
            <changefreq>daily</changefreq>
            <priority>0.7</priority>
          </url>
        """
      end)
      |> Enum.join()

    route_detail_urls =
      route_ids
      |> Enum.map(fn %{id: id} ->
        """
          <url>
            <loc>#{base}/routes/#{id}</loc>
            <changefreq>daily</changefreq>
            <priority>0.8</priority>
          </url>
        """
      end)
      |> Enum.join()

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      <url>
        <loc>#{base}/</loc>
        <changefreq>weekly</changefreq>
        <priority>1.0</priority>
      </url>
      <url>
        <loc>#{base}/how-it-works</loc>
        <changefreq>monthly</changefreq>
        <priority>0.6</priority>
      </url>
    #{pair_urls}#{route_detail_urls}#{from_city_urls}#{to_city_urls}#{zone_urls}</urlset>
    """
  end
end
