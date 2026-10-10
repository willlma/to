defmodule ToWeb.UserAuth do
  import Plug.Conn
  import Phoenix.Controller
  alias To.Accounts

  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user, Accounts.get_user(get_session(conn, :user_id)))
  end

  def require_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn |> redirect(to: "/") |> halt()
    end
  end

  def on_mount(:require_user, _params, session, socket) do
    case Accounts.get_user(session["user_id"]) do
      nil -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
      user -> {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    end
  end
end
