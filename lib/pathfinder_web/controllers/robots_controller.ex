defmodule PathfinderWeb.RobotsController do
  use PathfinderWeb, :controller

  def index(conn, _params) do
    base = PathfinderWeb.Endpoint.url()

    content = """
    User-agent: *
    Disallow: /admin/
    Disallow: /go
    Disallow: /health

    Sitemap: #{base}/sitemap.xml
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, content)
  end
end
