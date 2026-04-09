defmodule Pathfinder.Repo.Migrations.CreateCities do
  use Ecto.Migration

  def change do
    create table(:cities) do
      add :name, :string, null: false
      add :country, :string, null: false
      add :iata_codes, {:array, :string}, default: []
      add :lat, :float, null: false
      add :lng, :float, null: false
      add :is_active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cities, [:name])
    create index(:cities, [:is_active])
  end
end
