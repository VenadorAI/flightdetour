defmodule PathfinderWeb.PageController do
  use PathfinderWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
