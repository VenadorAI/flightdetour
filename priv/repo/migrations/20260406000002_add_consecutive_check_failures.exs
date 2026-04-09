defmodule Pathfinder.Repo.Migrations.AddConsecutiveCheckFailures do
  use Ecto.Migration

  def change do
    alter table(:disruption_zones) do
      add :consecutive_check_failures, :integer, default: 0, null: false
    end
  end
end
