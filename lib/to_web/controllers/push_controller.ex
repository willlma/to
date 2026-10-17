defmodule ToWeb.PushController do
  use ToWeb, :controller
  alias To.Reminders

  def create(conn, params) do
    if Reminders.configured?() do
      respond(conn, Reminders.subscribe(conn.assigns.current_user, params))
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "Notifications are not configured yet."})
    end
  end

  def delete(conn, %{"endpoint" => endpoint}) do
    respond(conn, Reminders.unsubscribe(conn.assigns.current_user, endpoint))
  end

  def delete(conn, _), do: respond(conn, {:error, :invalid_subscription})

  def test_notification(conn, params) do
    respond(conn, Reminders.test_notification(conn.assigns.current_user, params["endpoint"]))
  end

  def preferences(conn, %{"reminder_time" => time}) when is_binary(time) do
    respond(conn, Reminders.update_reminder_time(conn.assigns.current_user, time))
  end

  def preferences(conn, _), do: respond(conn, {:error, :invalid_time})

  defp respond(conn, {:ok, _}), do: json(conn, %{ok: true})
  defp respond(conn, :ok), do: json(conn, %{ok: true})

  defp respond(conn, {:error, _}),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Check your notification settings and try again."})
end
