defmodule Pathfinder.Workers.ObanErrorNotifier do
  @moduledoc """
  Telemetry handler for Oban job failures on critical workers.

  Attaches to Oban's telemetry events at application startup and emits
  Logger.error lines (with [critical] prefix) when critical workers are
  exhausted or raise unexpected exceptions.

  The [critical] prefix makes these easy to filter in platform log streams:
    fly logs | grep "\[critical\]"
    render logs | grep critical

  If Sentry is configured (SENTRY_DSN env var), Sentry automatically captures
  Oban exceptions via its global error handler — no additional wiring needed.

  Critical workers (failures alert here):
    - AdvisoryCheckJob  — source monitoring; silence = trust erosion
    - FreshnessUpdateJob — age-based freshness; silence = stale scores
  """

  require Logger

  @critical_workers [
    "Elixir.Pathfinder.Workers.AdvisoryCheckJob",
    "Elixir.Pathfinder.Workers.FreshnessUpdateJob"
  ]

  def attach do
    :telemetry.attach_many(
      "pathfinder-oban-errors",
      [
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:oban, :job, :stop], _measurements, meta, _config) do
    if meta.job.worker in @critical_workers and meta.state in [:exhausted, :discard] do
      Logger.error(
        "[critical] Oban job #{meta.job.worker} #{meta.state} after #{meta.job.max_attempts} attempts — " <>
          "queue: #{meta.job.queue}, id: #{meta.job.id}. " <>
          "Check /admin/review. Source monitoring may be degraded."
      )
    end
  end

  def handle_event([:oban, :job, :exception], _measurements, meta, _config) do
    if meta.job.worker in @critical_workers do
      Logger.error(
        "[critical] Oban job #{meta.job.worker} raised #{inspect(meta.kind)}: #{inspect(meta.reason)} — " <>
          "attempt #{meta.job.attempt}/#{meta.job.max_attempts}, id: #{meta.job.id}"
      )
    end
  end
end
