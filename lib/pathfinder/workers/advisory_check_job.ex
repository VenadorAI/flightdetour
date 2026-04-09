defmodule Pathfinder.Workers.AdvisoryCheckJob do
  @moduledoc """
  Oban job: fetch official advisory sources and detect changes.

  Scheduled every 6 hours via Oban.Plugins.Cron.
  Can also be triggered manually:

      Pathfinder.Workers.AdvisoryCheckJob.enqueue()

  When a source page hash changes, the job flags all linked route scores
  as "review_required". A human then confirms the change via /admin/review
  and marks affected routes as reviewed.
  """
  use Oban.Worker, queue: :disruption, max_attempts: 3

  require Logger
  alias Pathfinder.Advisory.EASAChecker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[AdvisoryCheckJob] Starting advisory source check")

    {:ok, results} = EASAChecker.check_all()
    changed = Enum.count(results, & &1[:changed])
    errors = Enum.count(results, & &1[:error])
    total = length(results)

    Logger.info("[AdvisoryCheckJob] Done — #{total} source(s) checked, #{changed} changed, #{errors} error(s)")

    # If every source fetch failed, this is a critical signal — not a transient blip.
    # Likely causes: network outage, EASA page structure change, SSL cert issue.
    if total > 0 and errors == total do
      Logger.error(
        "[critical] AdvisoryCheckJob: ALL #{total} source fetch(es) failed. " <>
          "Source monitoring is not running. Check network access and source URLs in /admin/review."
      )
    end

    :ok
  end

  def enqueue do
    %{} |> new() |> Oban.insert()
  end
end
