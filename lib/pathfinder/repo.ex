defmodule Pathfinder.Repo do
  use Ecto.Repo,
    otp_app: :pathfinder,
    adapter: Ecto.Adapters.Postgres
end
