defmodule To.E2E.Google do
  # OAuth's external provider is mocked; state, account policy and encrypted
  # token persistence still run through the application's real HTTP callback.
  def configured?, do: true

  def authorization_url(state, verifier) do
    "http://127.0.0.1:4010/authorize?" <>
      URI.encode_query(%{state: state, code_challenge: verifier})
  end

  def exchange(code, verifier), do: To.Accounts.Google.exchange(code, verifier)
end
