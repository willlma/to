defmodule To.PushSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    belongs_to :user, To.Accounts.User
    field :endpoint, :string, redact: true
    field :p256dh, :string, redact: true
    field :auth, :string, redact: true
    field :time_zone, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :endpoint, :p256dh, :auth, :time_zone])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth, :time_zone])
    |> validate_length(:endpoint, max: 4096)
    |> validate_change(:endpoint, fn :endpoint, endpoint ->
      case URI.parse(endpoint) do
        %URI{scheme: "https", host: host, port: 443, userinfo: nil} when is_binary(host) ->
          if push_host?(host), do: [], else: [endpoint: "unsupported push provider"]

        _ ->
          [endpoint: "must be a secure push endpoint"]
      end
    end)
    |> validate_change(:p256dh, &validate_key(&1, &2, 65))
    |> validate_change(:auth, &validate_key(&1, &2, 16))
    |> validate_change(:time_zone, fn :time_zone, zone ->
      case DateTime.shift_zone(DateTime.utc_now(), zone) do
        {:ok, _} -> []
        _ -> [time_zone: "is not a recognized timezone"]
      end
    end)
    |> unique_constraint(:endpoint)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_key(field, value, length) do
    case Base.url_decode64(String.trim_trailing(value, "="), padding: false) do
      {:ok, key} when byte_size(key) == length -> []
      _ -> [{field, "is not a valid push key"}]
    end
  end

  defp push_host?(host) do
    host == "fcm.googleapis.com" or host == "web.push.apple.com" or
      host == "updates.push.services.mozilla.com" or
      String.ends_with?(host, ".push.services.mozilla.com") or
      String.ends_with?(host, ".notify.windows.com")
  end
end
