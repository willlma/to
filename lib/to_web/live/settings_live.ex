defmodule ToWeb.SettingsLive do
  use ToWeb, :live_view
  alias To.Reminders

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, notice: nil, vapid_key: Application.get_env(:ex_nudge, :vapid_public_key))}
  end

  def handle_event("reminder-time", %{"time" => time}, socket) do
    case Reminders.update_reminder_time(socket.assigns.current_user, time) do
      {:ok, user} ->
        {:noreply, assign(socket, current_user: user, notice: "Reminder time saved.")}

      {:error, _} ->
        {:noreply, assign(socket, notice: "Choose a valid reminder time.")}
    end
  end

  def render(assigns) do
    ~H"""
    <main>
      <.link navigate={~p"/lists"}>Back to lists</.link>
      <h1>Settings</h1>
      <p>Assigned tasks remind you the day before, in each browser's timezone.</p>
      <.form for={%{}} id="reminder-form" phx-submit="reminder-time">
        <label>Reminder time<input
          name="time"
          type="time"
          value={Time.to_iso8601(@current_user.reminder_time)}
          required
        /></label><button>Save time</button>
      </.form>
      <button
        id="enable-notifications"
        type="button"
        phx-hook="Notifications"
        data-vapid-key={@vapid_key || ""}
      >Enable notifications</button>
      <p id="notification-status" role="status" phx-update="ignore"></p>
      <p>
        {if @current_user.google_refresh_token in [nil, ""],
          do: "Google not connected.",
          else: "Google Tasks connected."}
        <a href="/auth/google">Connect Google Tasks</a>
      </p>
      <small>On iPhone, add To to your Home Screen before enabling notifications.</small>
      <.form for={%{}} action="/logout" method="delete"><button>Sign out</button></.form>
      <p :if={@notice} role="status">{@notice}</p>
    </main>
    """
  end
end
