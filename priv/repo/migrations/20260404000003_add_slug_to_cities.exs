defmodule Pathfinder.Repo.Migrations.AddSlugToCities do
  use Ecto.Migration

  def change do
    alter table(:cities) do
      add :slug, :string
    end

    create unique_index(:cities, [:slug])
  end
end
