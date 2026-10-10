defmodule To.Repo do
  use Ecto.Repo,
    otp_app: :to,
    adapter: Ecto.Adapters.SQLite3
end
