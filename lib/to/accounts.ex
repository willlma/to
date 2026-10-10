defmodule To.Accounts do
  import Ecto.Query
  alias To.Accounts.User
  alias To.Repo

  def ensure_household_users do
    for name <- ["Nicole", "Will"] do
      %User{}
      |> User.changeset(%{name: name})
      |> Repo.insert(on_conflict: :nothing, conflict_target: :name)
    end

    :ok
  end

  def list_users do
    ensure_household_users()
    Repo.all(from(u in User, order_by: u.name))
  end

  def get_user(id) when is_integer(id), do: Repo.get(User, id)
  def get_user(_), do: nil

  def upsert_google_user(profile, tokens) do
    with true <- profile["email_verified"] in [true, "true"],
         sub when is_binary(sub) and byte_size(sub) > 0 <- profile["sub"],
         {:ok, name} <- allowed_name(profile["email"]) do
      ensure_household_users()

      Repo.transaction(fn ->
        user = Repo.get_by!(User, name: name)

        if user.google_sub && user.google_sub != sub do
          Repo.rollback(:account_mismatch)
        end

        attrs = %{email: String.downcase(profile["email"]), google_sub: sub}

        attrs =
          case tokens["refresh_token"] do
            token when is_binary(token) and byte_size(token) > 0 ->
              Map.put(
                attrs,
                :google_refresh_token,
                Phoenix.Token.encrypt(ToWeb.Endpoint, "google-refresh", token)
              )

            _ ->
              attrs
          end

        case Repo.update(User.changeset(user, attrs)) do
          {:ok, user} -> user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      _ -> {:error, :not_allowed}
    end
  end

  def refresh_token(%User{google_refresh_token: token}) when is_binary(token) do
    Phoenix.Token.decrypt(ToWeb.Endpoint, "google-refresh", token, max_age: :infinity)
  end

  def refresh_token(_), do: {:error, :not_connected}

  defp allowed_name(email) when is_binary(email) do
    config = Application.get_env(:to, :google_oauth, [])
    email = String.downcase(email)

    [{"Nicole", config[:nicole_email]}, {"Will", config[:will_email]}]
    |> Enum.filter(fn {_, allowed} -> is_binary(allowed) && String.downcase(allowed) == email end)
    |> case do
      [{name, _}] -> {:ok, name}
      _ -> {:error, :not_allowed}
    end
  end

  defp allowed_name(_), do: {:error, :not_allowed}

  if Mix.env() == :dev do
    def development_user(person) do
      if System.get_env("APP_DEV_LOGIN") == "true" && person in ["nicole", "will"] do
        ensure_household_users()
        {:ok, Repo.get_by!(User, name: String.capitalize(person))}
      else
        {:error, :disabled}
      end
    end
  end
end
