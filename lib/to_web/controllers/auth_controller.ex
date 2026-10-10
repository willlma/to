defmodule ToWeb.AuthController do
  use ToWeb, :controller
  alias To.Accounts
  alias To.Accounts.Google

  def request(conn, _params) do
    if provider().configured?() do
      state = random_token()
      verifier = random_token()

      conn
      |> put_session(:oauth_state, state)
      |> put_session(:oauth_verifier, verifier)
      |> put_session(:oauth_started_at, System.system_time(:second))
      |> redirect(external: provider().authorization_url(state, verifier))
    else
      conn |> put_flash(:error, "Google sign-in needs configuration.") |> redirect(to: "/")
    end
  end

  def callback(conn, params) do
    state = get_session(conn, :oauth_state)
    verifier = get_session(conn, :oauth_verifier)
    started_at = get_session(conn, :oauth_started_at)

    conn =
      conn
      |> delete_session(:oauth_state)
      |> delete_session(:oauth_verifier)
      |> delete_session(:oauth_started_at)

    with true <- valid_state?(state, params["state"], started_at),
         code when is_binary(code) <- params["code"],
         {:ok, profile, tokens} <- provider().exchange(code, verifier),
         {:ok, user} <- Accounts.upsert_google_user(profile, tokens) do
      To.Sync.enqueue_for_user(user)
      sign_in(conn, user)
    else
      _ ->
        conn
        |> put_flash(
          :error,
          "Sign-in failed. Only Nicole and Will can use this app. Please try again."
        )
        |> redirect(to: "/")
    end
  end

  def logout(conn, _params) do
    conn |> configure_session(drop: true) |> redirect(to: "/")
  end

  if Mix.env() == :dev do
    def development_login(conn, %{"person" => person}) do
      case Accounts.development_user(person) do
        {:ok, user} -> sign_in(conn, user)
        _ -> send_resp(conn, 404, "Not found")
      end
    end
  end

  defp sign_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
    |> redirect(to: "/lists")
  end

  defp valid_state?(expected, actual, started_at)
       when is_binary(expected) and is_binary(actual) and is_integer(started_at) do
    age = System.system_time(:second) - started_at
    age in 0..600 && Plug.Crypto.secure_compare(expected, actual)
  end

  defp valid_state?(_, _, _), do: false
  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  if Mix.env() == :test do
    defp provider, do: Application.get_env(:to, :google_auth_provider, Google)
  else
    defp provider, do: Google
  end
end
