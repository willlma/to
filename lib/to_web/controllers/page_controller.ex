defmodule ToWeb.PageController do
  use ToWeb, :controller

  def privacy(conn, _params), do: render(conn, :privacy)

  def home(conn, _params) do
    if conn.assigns.current_user do
      redirect(conn, to: ~p"/lists")
    else
      render(conn, :home,
        google_configured: To.Accounts.Google.configured?(),
        dev_login:
          Application.get_env(:to, :dev_routes, false) &&
            System.get_env("APP_DEV_LOGIN") == "true"
      )
    end
  end
end
