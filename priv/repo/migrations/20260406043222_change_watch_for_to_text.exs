defmodule Pathfinder.Repo.Migrations.ChangeWatchForToText do
  use Ecto.Migration

  def change do
    alter table(:route_scores) do
      modify :watch_for, :text, from: :string
    end
  end
end
