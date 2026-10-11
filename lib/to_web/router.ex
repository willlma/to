defmodule ToWeb.Router do
  use ToWeb, :router
  import ToWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ToWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :authenticated do
    plug :require_user
  end

  scope "/", ToWeb do
    pipe_through :browser
    get "/", PageController, :home
    get "/auth/google", AuthController, :request
    get "/auth/google/callback", AuthController, :callback
    delete "/logout", AuthController, :logout

    live_session :household, on_mount: [{ToWeb.UserAuth, :require_user}] do
      live "/settings", SettingsLive
      live "/lists", ListLive
      live "/lists/:id", ListLive
    end
  end

  scope "/api/push", ToWeb do
    pipe_through [:browser, :authenticated]
    post "/subscriptions", PushController, :create
    delete "/subscriptions", PushController, :delete
    patch "/preferences", PushController, :preferences
  end

  if Application.compile_env(:to, :dev_routes, false) do
    scope "/dev", ToWeb do
      pipe_through :browser
      get "/login/:person", AuthController, :development_login
    end
  end
end
