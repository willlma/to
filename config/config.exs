# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :to,
  ecto_repos: [To.Repo],
  generators: [timestamp_type: :utc_datetime]

config :to, To.Repo, default_transaction_mode: :immediate, busy_timeout: 10_000

config :elixir_make, :force_build, exqlite: true

config :to, Oban,
  repo: To.Repo,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  peer: Oban.Peers.Isolated,
  queues: [google_sync: 1, reminders: 1],
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

config :phoenix, :filter_parameters, [
  "password",
  "access_token",
  "refresh_token",
  "code",
  "oauth_verifier",
  "client_secret",
  "auth",
  "p256dh",
  "endpoint"
]

# Configure the endpoint
config :to, ToWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ToWeb.ErrorHTML, json: ToWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: To.PubSub,
  live_view: [signing_salt: "aIVmgP/s"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  to: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
