defmodule ToWeb.UserAuth do
  import Plug.Conn
  import Phoenix.Controller
  alias To.Accounts

  def fetch_current_user(conn, _opts) do
    user = Accounts.get_user(get_session(conn, :user_id))
    conn = assign(conn, :current_user, user)

    # Keep returning users signed in and upgrade existing session-only cookies.
    if user, do: configure_session(conn, renew: true), else: conn
  end

  def require_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn |> redirect(to: "/") |> halt()
    end
  end

  def require_pebble_token(conn, _opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %Accounts.User{} = user <- Accounts.authenticate_pebble_token(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", "Bearer realm=\"Town\"")
        |> put_status(:unauthorized)
        |> json(%{error: "A valid Pebble token is required."})
        |> halt()
    end
  end

  def on_mount(:require_user, _params, session, socket) do
    case Accounts.get_user(session["user_id"]) do
      nil -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
      user -> {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    end
  end
end
