import Config

config :to, To.Repo,
  database: System.get_env("E2E_DB_PATH") || Path.expand("../to_test.db", __DIR__),
  pool_size: 5,
  default_transaction_mode: :immediate,
  busy_timeout: 10_000

config :to, ToWeb.Endpoint,
  url: [host: "127.0.0.1", port: 4002],
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CDDUxBVMdI9tavMyXCmHC1ImPbOzc/lL82oohv+S3Tp2xDPdmsRmB/SLql2LmuMc",
  server: System.get_env("E2E_SERVER") == "1"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix, sort_verified_routes_query_params: true

if System.get_env("E2E_SERVER") == "1" do
  config :to, :google_oauth,
    client_id: "test-client",
    client_secret: "test-secret",
    redirect_uri: "http://127.0.0.1:4002/auth/google/callback",
    nicole_email: "nicole@example.test",
    will_email: "will@example.test"

  config :to,
    google_auth_provider: To.E2E.Google,
    push_transport: To.E2E.Push,
    google_tasks_api: "http://127.0.0.1:4010/tasks/v1",
    google_token_url: "http://127.0.0.1:4010/token",
    google_profile_url: "http://127.0.0.1:4010/profile"
end
