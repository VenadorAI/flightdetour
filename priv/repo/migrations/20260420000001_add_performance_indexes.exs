defmodule Pathfinder.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  def change do
    # routes(destination_city_id) — used by origins_to_city/1.
    # The existing composite (origin_city_id, destination_city_id) cannot satisfy
    # a WHERE destination_city_id = ? clause efficiently — Postgres cannot use the
    # right side of a composite index without the left side.
    create index(:routes, [:destination_city_id])

    # Partial indexes covering the is_active = true filter that appears on every
    # route query. Postgres can use a partial index directly without evaluating
    # the boolean filter, and the index is smaller (excludes inactive routes).
    create index(:routes, [:origin_city_id],
      where: "is_active = true",
      name: :routes_active_origin_idx
    )
    create index(:routes, [:destination_city_id],
      where: "is_active = true",
      name: :routes_active_destination_idx
    )

    # Composite covering index for all time-windowed analytics queries.
    # top_searched_pairs/2, top_origins/2, top_destinations/2 all filter
    # WHERE event_name = ? AND inserted_at >= ?, then group/count.
    # A composite (event_name, inserted_at) lets Postgres seek directly to the
    # relevant event type and time window without scanning the full table.
    create index(:search_events, [:event_name, :inserted_at])
  end
end
