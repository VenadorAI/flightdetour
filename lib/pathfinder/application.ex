defmodule Pathfinder.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attach Oban failure telemetry before starting children so no events are missed.
    Pathfinder.Workers.ObanErrorNotifier.attach()

    children = [
      PathfinderWeb.Telemetry,
      Pathfinder.Repo,
      {DNSCluster, query: Application.get_env(:pathfinder, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pathfinder.PubSub},
      Pathfinder.RouteCache,
      {Oban, Application.fetch_env!(:pathfinder, Oban)},
      PathfinderWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pathfinder.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PathfinderWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
