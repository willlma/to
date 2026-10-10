defmodule To.E2E.Push do
  # Failure modes this end-to-end boundary must expose: invalid curve keys,
  # obsolete content encryption/VAPID headers, and an HTTPoison upgrade that
  # breaks ExNudge's request or response contract. Encrypt and send through the
  # actual library to loopback before recording the readable test payload.
  def send_notification(subscription, payload, opts) do
    local = %{subscription | endpoint: "http://127.0.0.1:4010/__encrypted_push"}

    with {:ok, _} <- ExNudge.send_notification(local, payload, opts) do
      case Req.post("http://127.0.0.1:4010/__push",
             json: %{endpoint: subscription.endpoint, payload: Jason.decode!(payload)},
             retry: false
           ) do
        {:ok, %{status: 200}} -> {:ok, :delivered}
        _ -> {:error, :mock_push_failed}
      end
    end
  end
end
