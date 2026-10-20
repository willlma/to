{:ok, _} = To.E2E.Mock.start_link()

:telemetry.attach(
  "e2e-sync-completion-delay",
  [:oban, :engine, :complete_job, :start],
  &To.E2E.Mock.delay_sync_completion/4,
  nil
)

{:ok, _} = Bandit.start_link(plug: To.E2E.Mock, port: 4010, ip: {127, 0, 0, 1})
To.Accounts.ensure_household_users()
[default | _] = To.Tasks.list_lists()
will = Enum.find(To.Accounts.list_users(), &(&1.name == "Will"))
nicole = Enum.find(To.Accounts.list_users(), &(&1.name == "Nicole"))

{:ok, unedited} = To.Tasks.create_task(will, default.id, %{title: "Unedited legacy fixture"})

unedited
|> Ecto.Changeset.change(last_changed_fields: nil, updated_at: unedited.created_at)
|> To.Repo.update!()

# Completion regression cases: yesterday's completion belongs at the bottom,
# while today's completion stays in its group even if it is hours old.
today = DateTime.now!("America/Los_Angeles") |> DateTime.to_date()
midnight = DateTime.new!(today, ~T[00:00:00], "America/Los_Angeles")

for {title, completed_at} <- [
      {"Archived fixture", DateTime.add(midnight, -1, :second)},
      {"Recent completion fixture", midnight}
    ] do
  {:ok, task} =
    To.Tasks.create_task(will, default.id, %{title: title, nested_under: "Housekeeping"})

  task
  |> Ecto.Changeset.change(
    completed_at: DateTime.shift_zone!(completed_at, "Etc/UTC"),
    updated_at: DateTime.add(task.created_at, 1, :second),
    updated_by_id: if(title == "Recent completion fixture", do: nicole.id, else: will.id),
    last_changed_fields: nil
  )
  |> To.Repo.update!()
end

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
