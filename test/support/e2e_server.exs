{:ok, _} = To.E2E.Mock.start_link()
{:ok, _} = Bandit.start_link(plug: To.E2E.Mock, port: 4010, ip: {127, 0, 0, 1})
To.Accounts.ensure_household_users()
[default | _] = To.Tasks.list_lists()
will = Enum.find(To.Accounts.list_users(), &(&1.name == "Will"))
{:ok, old} = To.Tasks.create_task(will, default.id, %{title: "Archived fixture"})

old
|> Ecto.Changeset.change(
  completed_at:
    DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -25 * 3600, :second)
)
|> To.Repo.update!()

# Ephemeral keys exercise actual RFC 8291 encryption and VAPID signing against
# the loopback receiver; no real provider credentials or devices are involved.
vapid = ExNudge.generate_vapid_keys()
Application.put_env(:ex_nudge, :vapid_public_key, vapid.public_key)
Application.put_env(:ex_nudge, :vapid_private_key, vapid.private_key)
Application.put_env(:ex_nudge, :vapid_subject, "mailto:e2e@example.test")
{device_public_key, _device_private_key} = :crypto.generate_key(:ecdh, :prime256v1)
{:ok, will} = To.Reminders.update_reminder_time(will, "09:00")

{:ok, _} =
  To.Reminders.subscribe(will, %{
    "endpoint" => "https://fcm.googleapis.com/e2e",
    "keys" => %{
      "p256dh" => Base.url_encode64(device_public_key, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    },
    "time_zone" => "America/Los_Angeles"
  })

Agent.update(To.E2E.Mock, &Map.put(&1, :ready, true))
# Keep the linked mock HTTP server and agent alive for the browser run.
receive do
  :stop -> :ok
end
