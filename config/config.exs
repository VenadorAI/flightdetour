# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pathfinder,
  ecto_repos: [Pathfinder.Repo],
  generators: [timestamp_type: :utc_datetime],
  env: Mix.env()

# Configure the endpoint
config :pathfinder, PathfinderWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PathfinderWeb.ErrorHTML, json: PathfinderWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pathfinder.PubSub,
  live_view: [signing_salt: "bqq9F6Fw"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  pathfinder: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  pathfinder: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Oban background job processing
config :pathfinder, Oban,
  engine: Oban.Engines.Basic,
  repo: Pathfinder.Repo,
  queues: [default: 10, disruption: 5],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Check advisory sources every 6 hours
       {"0 */6 * * *", Pathfinder.Workers.AdvisoryCheckJob},
       # Recompute age-based freshness daily at 03:00 UTC
       {"0 3 * * *", Pathfinder.Workers.FreshnessUpdateJob}
     ]}
  ]

# Sentry error tracking — activate by setting SENTRY_DSN in production.
# DSN is loaded in runtime.exs. This block sets defaults for all envs.
config :sentry,
  dsn: nil,
  environment_name: Mix.env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  client: Sentry.HackneyClient

# Outbound search link providers (order determines display order; first = primary CTA)
# Supported keys: :google_flights, :skyscanner
# Remove a key to disable that provider globally.
config :pathfinder, Pathfinder.Outbound,
  providers: [:skyscanner, :google_flights]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
