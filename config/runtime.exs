import Config

port =
  String.to_integer(System.get_env("PORT", if(config_env() == :test, do: "4002", else: "4000")))

host = System.get_env("PHX_HOST", "localhost")
config :to, ToWeb.Endpoint, http: [port: port]
if System.get_env("PHX_SERVER"), do: config(:to, ToWeb.Endpoint, server: true)

if config_env() != :test do
  config :to, :google_oauth,
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
    redirect_uri:
      System.get_env(
        "GOOGLE_REDIRECT_URI",
        if(config_env() == :prod,
          do: "https://#{host}/auth/google/callback",
          else: "http://localhost:#{port}/auth/google/callback"
        )
      ),
    nicole_email: System.get_env("NICOLE_GOOGLE_EMAIL"),
    will_email: System.get_env("WILL_GOOGLE_EMAIL")

  config :ex_nudge,
    vapid_public_key: System.get_env("VAPID_PUBLIC_KEY"),
    vapid_private_key: System.get_env("VAPID_PRIVATE_KEY"),
    vapid_subject: System.get_env("VAPID_SUBJECT", "mailto:hello@example.com")
end

if config_env() == :dev do
  config :to, ToWeb.Endpoint,
    live_reload: [
      patterns: [~r"priv/static/.*\.(js|css|png|svg)$", ~r"lib/to_web/.*\.(ex|heex)$"]
    ]
end

if config_env() == :prod do
  config :to, To.Repo, database: System.fetch_env!("DATABASE_PATH"), pool_size: 5

  config :to, ToWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
