defmodule PathfinderWeb.PageControllerTest do
  use PathfinderWeb.ConnCase

  test "home page loads and contains product identity", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Pathfinder"
    assert body =~ "disruption"
  end
end
