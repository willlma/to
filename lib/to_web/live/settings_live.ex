defmodule ToWeb.SettingsLive do
  use ToWeb, :live_view
  alias To.Reminders

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       notice: nil,
       importing: false,
       google_reconnect: false,
       vapid_key: Application.get_env(:ex_nudge, :vapid_public_key)
     )}
  end

  def handle_event("import-google", _, socket) do
    user = socket.assigns.current_user

    cond do
      !To.Sync.enabled?() ->
        {:noreply, assign(socket, notice: "Google sync is disabled for local development.")}

      socket.assigns.importing ->
        {:noreply, socket}

      socket.assigns.google_reconnect || user.google_refresh_token in [nil, ""] ->
        {:noreply, redirect(socket, to: ~p"/auth/google")}

      true ->
        {:noreply,
         socket
         |> assign(importing: true, notice: nil)
         |> start_async(:google_import, fn -> To.Sync.import_tasks(user) end)}
    end
  end

  def handle_event("reminder-time", %{"time" => time}, socket) do
    case Reminders.update_reminder_time(socket.assigns.current_user, time) do
      {:ok, user} ->
        {:noreply, assign(socket, current_user: user, notice: "Reminder time saved.")}

      {:error, _} ->
        {:noreply, assign(socket, notice: "Choose a valid reminder time.")}
    end
  end

  def handle_async(:google_import, {:ok, {:ok, counts}}, socket) do
    notice =
      "Imported #{counts.imported} tasks. Skipped #{counts.skipped} already imported or exported tasks."

    notice =
      if counts.invalid > 0,
        do:
          notice <>
            " #{counts.invalid} tasks could not be imported because their data is unsupported.",
        else: notice

    {:noreply, assign(socket, importing: false, notice: notice)}
  end

  def handle_async(:google_import, {:ok, {:error, :google_reconnect_required}}, socket),
    do:
      {:noreply,
       assign(socket,
         importing: false,
         google_reconnect: true,
         notice:
           "Google access has expired or was revoked. Reconnect to try importing again. Nothing was imported."
       )}

  def handle_async(:google_import, _, socket),
    do:
      {:noreply,
       assign(socket,
         importing: false,
         notice: "Import failed. Please try again. Nothing was imported."
       )}

  def render(assigns) do
    ~H"""
    <style :type={ToWeb.ColocatedCSS}>
      #enable-notifications { margin-top: 1rem; }
      #notification-status { margin: .25rem 0; }
      #reminder-form { display: flex; align-items: center; flex-wrap: wrap; gap: .5rem; }
      #reminder-form p { flex-basis: 100%; margin: 1rem 0 0; }
      #reminder-form label { display: inline; margin: 0; }
      #reminder-form input { flex: 1; min-width: 0; }
      #reminder-form button { flex-shrink: 0; }
      #google-import-form { margin: 1rem 0; }
    </style>
    <main>
      <.link navigate={~p"/lists"}>Back to lists</.link>
      <h1>Settings</h1>
      <.form for={%{}} id="reminder-form" phx-submit="reminder-time">
        <p>
          <label for="reminder-time">
            Assigned tasks remind you the day before, in each browser's timezone. Reminder time:
          </label>
        </p>
        <input
          id="reminder-time"
          name="time"
          type="time"
          value={Time.to_iso8601(@current_user.reminder_time)}
          required
        /><button>Save time</button>
      </.form>
      <button
        id="enable-notifications"
        type="button"
        phx-hook=".Notifications"
        phx-update="ignore"
        data-vapid-key={@vapid_key || ""}
      >Enable notifications</button>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Notifications">
        export default {
          mounted() {
            const csrf = document.querySelector('meta[name="csrf-token"]').content;
            this.status = message => {
              const status = document.getElementById("notification-status");
              if (status) status.textContent = message;
            };
            this.supported = () => {
              const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
                (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
              if (ios && !navigator.standalone && !matchMedia("(display-mode: standalone)").matches) {
                this.status("Add To to your Home Screen, then open it there to enable notifications.");
                return false;
              }
              if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
                this.status("This browser does not support notifications. On iPhone use iOS 16.4 or later.");
                return false;
              }
              if (!this.el.dataset.vapidKey) {
                this.status("Notifications need server setup before they can be enabled.");
                return false;
              }
              return true;
            };
            this.save = async subscription => {
              const response = await fetch("/api/push/subscriptions", {
                method: "POST",
                headers: {"Content-Type": "application/json", "x-csrf-token": csrf},
                body: JSON.stringify({...subscription.toJSON(), time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone})
              });
              if (!response.ok) throw new Error("Could not save notifications. Check your connection and try again.");
              this.subscription = subscription;
              this.el.textContent = "Test notification";
              this.status("");
            };
            this.refresh = async () => {
              if (!this.supported() || Notification.permission !== "granted") return;
              const registration = await navigator.serviceWorker.register("/sw.js");
              const subscription = await registration.pushManager.getSubscription();
              if (subscription) await this.save(subscription);
            };
            this.click = async () => {
              if (!this.supported()) return;
              this.el.disabled = true;
              try {
                if (this.subscription && Notification.permission === "granted") {
                  const response = await fetch("/api/push/test", {
                    method: "POST",
                    headers: {"Content-Type": "application/json", "x-csrf-token": csrf},
                    body: JSON.stringify({endpoint: this.subscription.endpoint})
                  });
                  if (!response.ok) throw new Error("Could not send the test notification. Check your connection and notification settings.");
                  this.status("Test notification sent.");
                  return;
                }
                // Request permission directly in the click handler for iOS user activation.
                const permission = await Notification.requestPermission();
                if (permission !== "granted") {
                  this.status("Notification permission was not granted. You can change it in your device settings.");
                  return;
                }
                await navigator.serviceWorker.register("/sw.js");
                const registration = await navigator.serviceWorker.ready;
                const key = this.el.dataset.vapidKey;
                const raw = atob((key + "=".repeat((4 - key.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/"));
                const applicationServerKey = Uint8Array.from(raw, c => c.charCodeAt(0));
                const subscription = await registration.pushManager.getSubscription() ||
                  await registration.pushManager.subscribe({userVisibleOnly: true, applicationServerKey});
                await this.save(subscription);
              } catch (error) {
                this.status(error.message || "Could not enable notifications. Try again.");
              } finally {
                this.el.disabled = false;
              }
            };
            this.el.addEventListener("click", this.click);
            this.refresh().catch(() => this.status("Could not refresh notifications. Check your connection."));
          },
          reconnected() {
            this.refresh().catch(() => this.status("Could not refresh notifications. Check your connection."));
          },
          destroyed() { this.el.removeEventListener("click", this.click); }
        }
      </script>
      <p id="notification-status" role="status" phx-update="ignore"></p>
      <small>On iPhone, add To to your Home Screen before enabling notifications.</small>
      <%= if To.Sync.enabled?() do %>
        <.form for={%{}} id="google-import-form" phx-submit="import-google">
          <button disabled={@importing}>
            {cond do
              @importing -> "Importing…"
              @google_reconnect -> "Reconnect to Google"
              @current_user.google_refresh_token in [nil, ""] -> "Connect to Google"
              true -> "Import Google Tasks"
            end}
          </button>
        </.form>
      <% else %>
        <p>Google sync is disabled for local development.</p>
      <% end %>
      <.form for={%{}} action="/logout" method="delete"><button>Sign out</button></.form>
      <p><.link href={~p"/pp"}>Privacy policy</.link></p>
      <p :if={@notice} role="status">{@notice}</p>
    </main>
    """
  end
end
